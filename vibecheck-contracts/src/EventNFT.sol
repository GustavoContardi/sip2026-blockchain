// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Pausable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol";
import {ERC721Royalty} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title EventNFT
 * @notice ERC-721 de entradas para un evento específico.
 *         Un EventNFT por evento (deployado por EventFactory).
 *
 *         Modelo:
 *           - Tiers (VIP, General, Platea) con precio en USDC y supply fijo.
 *           - Mint-on-sale: solo el OfferingNFT (MINTER_ROLE) puede acuñar.
 *           - Royalty 5% al organizador vía EIP-2981 (lo respetan marketplaces externos
 *             que implementen el estándar; el marketplace interno SIEMPRE lo enforza).
 *           - Soulbound parcial: transferencias P2P bloqueadas; solo MARKET_ROLE
 *             (NFTMarketplace) puede mover NFTs entre wallets. Mints y burns libres.
 *           - Tope de reventa por evento: `maxResalePriceBps` * `originalPrice[tokenId]`.
 *           - Check-in on-chain: `redeem()` con firma del `venueSigner`. Marca el
 *             tokenId como usado, bloquea futuras transferencias, y dispara mutación
 *             de `tokenURI` (entrada → coleccionable).
 */
contract EventNFT is ERC721, ERC721Pausable, ERC721Royalty, AccessControl, Ownable {
    using Strings for uint256;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    /// @notice Definición de un tier de entradas. El tope de reventa se define por tier
    ///         para permitir políticas distintas entre VIP, General, Preventa, etc.
    struct Tier {
        string name;                // "VIP", "Campo", "Platea", "Preventa"
        uint256 priceUSDC;          // 6 decimales (USDC)
        uint256 supply;             // máximo de tickets de este tier
        uint256 sold;               // contador de vendidos
        uint16 maxResalePriceBps;   // tope de reventa en bps (10000=100%, 12000=120%)
    }

    // -----------------------------------------------------------------
    // Estado del evento
    // -----------------------------------------------------------------

    address public immutable organizer;
    address public immutable factory;
    uint256 public immutable eventDate;         // timestamp UNIX del evento

    address public venueSigner;                 // firma off-chain los QRs en puerta
    string  private _baseTokenURI;

    Tier[] public tiers;

    uint256 private _nextId;

    /// @notice Tier al que pertenece cada token.
    mapping(uint256 => uint256) public tokenTier;
    /// @notice Precio nominal en USDC pagado en la venta primaria.
    ///         Sirve como referencia para el tope de reventa.
    mapping(uint256 => uint256) public originalPrice;
    /// @notice Si el token ya fue usado para entrar al evento.
    mapping(uint256 => bool) public redeemed;
    /// @notice Si el holder asistió (controla la mutación del tokenURI).
    mapping(uint256 => bool) public attended;

    // -----------------------------------------------------------------
    // Eventos y errores
    // -----------------------------------------------------------------

    event TicketSold(address indexed buyer, uint256 indexed tokenId, uint256 indexed tierIdx, uint256 priceUSDC);
    event Redeemed(uint256 indexed tokenId, address indexed by);
    event VenueSignerUpdated(address indexed previous, address indexed next);
    event BaseURIUpdated(string newBaseURI);

    error TierOutOfRange();
    error TierSoldOut();
    error EventOver();
    error AlreadyRedeemed();
    error InvalidSignature();
    error CheckInWindowClosed();
    error TransferNotAllowed();
    error ZeroAddress();
    error EmptyTiers();
    error InvalidTierSupply();
    error EventDateInPast();
    error InvalidResaleCap();

    /// @notice Parámetros agrupados para evitar stack too deep en el constructor.
    struct InitParams {
        string name;
        string symbol;
        address organizer;
        uint256 eventDate;
        address venueSigner;
        string baseURI;
    }

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    constructor(InitParams memory p, Tier[] memory tiers_)
        ERC721(p.name, p.symbol)
        Ownable(p.organizer)
    {
        if (p.organizer == address(0) || p.venueSigner == address(0)) revert ZeroAddress();
        if (p.eventDate <= block.timestamp) revert EventDateInPast();
        if (tiers_.length == 0) revert EmptyTiers();

        organizer = p.organizer;
        factory = msg.sender;
        eventDate = p.eventDate;
        venueSigner = p.venueSigner;
        _baseTokenURI = p.baseURI;

        for (uint256 i = 0; i < tiers_.length; i++) {
            if (tiers_[i].supply == 0) revert InvalidTierSupply();
            // Tope por tier: mínimo 100% (no se puede revender por menos del 100% — sí, este
            // tope solo acota el techo; vender más barato siempre se puede). Máximo 1000% como
            // sanity check para evitar valores accidentales sin sentido.
            if (tiers_[i].maxResalePriceBps < 10_000 || tiers_[i].maxResalePriceBps > 100_000) {
                revert InvalidResaleCap();
            }
            // `sold` se inicializa en 0 sin importar lo que mande el factory.
            tiers.push(Tier({
                name: tiers_[i].name,
                priceUSDC: tiers_[i].priceUSDC,
                supply: tiers_[i].supply,
                sold: 0,
                maxResalePriceBps: tiers_[i].maxResalePriceBps
            }));
        }

        // Royalty 5% al organizador (EIP-2981)
        _setDefaultRoyalty(p.organizer, 500);

        // Factory (deployer) y organizer son admins de roles del NFT.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, p.organizer);

        emit VenueSignerUpdated(address(0), p.venueSigner);
    }

    // -----------------------------------------------------------------
    // Admin (organizador)
    // -----------------------------------------------------------------

    function setVenueSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit VenueSignerUpdated(venueSigner, newSigner);
        venueSigner = newSigner;
    }

    function setBaseURI(string calldata newBase) external onlyOwner {
        _baseTokenURI = newBase;
        emit BaseURIUpdated(newBase);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -----------------------------------------------------------------
    // Minting (solo OfferingNFT)
    // -----------------------------------------------------------------

    /// @notice Acuña un ticket en la venta primaria. Solo el OfferingNFT.
    /// @param to       comprador
    /// @param tierIdx  índice del tier elegido
    /// @param paidUSDC precio nominal en USDC del tier (referencia para tope de reventa)
    function mintTicket(address to, uint256 tierIdx, uint256 paidUSDC)
        external
        onlyRole(MINTER_ROLE)
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (block.timestamp >= eventDate) revert EventOver();
        if (tierIdx >= tiers.length) revert TierOutOfRange();

        Tier storage t = tiers[tierIdx];
        if (t.sold >= t.supply) revert TierSoldOut();
        t.sold += 1;

        tokenId = ++_nextId;
        tokenTier[tokenId] = tierIdx;
        originalPrice[tokenId] = paidUSDC;

        _mint(to, tokenId);
        emit TicketSold(to, tokenId, tierIdx, paidUSDC);
    }

    // -----------------------------------------------------------------
    // Check-in (redeem con firma del venue)
    // -----------------------------------------------------------------

    /**
     * @notice Marca un ticket como usado. Requiere firma del venueSigner.
     * @dev El mensaje firmado es `keccak256(abi.encode(address(this), tokenId, chainid))`.
     *      El venue firma off-chain, el fan presenta tokenId + signature.
     *      Ventana de check-in: desde 1 día antes hasta 1 día después del evento.
     */
    function redeem(uint256 tokenId, bytes calldata signature) external {
        if (ownerOf(tokenId) != msg.sender) revert TransferNotAllowed();
        if (redeemed[tokenId]) revert AlreadyRedeemed();

        // Ventana: [eventDate - 1 day, eventDate + 1 day]
        if (block.timestamp < eventDate - 1 days || block.timestamp > eventDate + 1 days) {
            revert CheckInWindowClosed();
        }

        bytes32 digest = keccak256(abi.encode(address(this), tokenId, block.chainid))
            .toEthSignedMessageHash();
        address recovered = digest.recover(signature);
        if (recovered != venueSigner) revert InvalidSignature();

        redeemed[tokenId] = true;
        attended[tokenId] = true;
        emit Redeemed(tokenId, msg.sender);
    }

    // -----------------------------------------------------------------
    // Helpers de lectura
    // -----------------------------------------------------------------

    /// @notice Precio máximo al que se puede revender este token (en USDC).
    ///         El tope viene del tier al que pertenece el token.
    function maxResalePrice(uint256 tokenId) external view returns (uint256) {
        uint256 tierIdx = tokenTier[tokenId];
        return (originalPrice[tokenId] * tiers[tierIdx].maxResalePriceBps) / 10_000;
    }

    /// @notice Cuántos tiers tiene este evento.
    function tiersLength() external view returns (uint256) {
        return tiers.length;
    }

    /// @notice Total acuñado hasta ahora.
    function totalMinted() external view returns (uint256) {
        return _nextId;
    }

    // -----------------------------------------------------------------
    // tokenURI dinámico (entrada → coleccionable)
    // -----------------------------------------------------------------

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory base = _baseTokenURI;
        if (bytes(base).length == 0) return "";
        string memory kind = attended[tokenId] ? "collectible/" : "ticket/";
        return string.concat(base, kind, tokenId.toString());
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // -----------------------------------------------------------------
    // Soulbound parcial: transferencias controladas
    // -----------------------------------------------------------------

    /**
     * @dev Reglas de transferencia:
     *      - Mint (from == 0) y burn (to == 0): permitidos.
     *      - Post-redeem: nadie puede transferir (entrada usada).
     *      - Post-eventDate: nadie puede transferir (evento pasó).
     *      - Pre-evento: solo el organizador o quien tenga MARKET_ROLE puede mover.
     *        Esto fuerza que toda reventa pase por el NFTMarketplace, donde se
     *        cobra royalty y se enforza el tope de precio.
     *
     *      `auth` es el operator de la transferencia. Lo provee OZ v5:
     *      - Si el owner llama directamente `transferFrom`, `auth == owner`.
     *      - Si llama un approved/operator, `auth == ese operator`.
     *      Por eso, un fan que llame `transferFrom` directo a otra wallet falla
     *      (porque su address no tiene MARKET_ROLE), pero el marketplace pasa.
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Pausable)
        returns (address)
    {
        address from = _ownerOf(tokenId);

        // Transferencia real (no mint ni burn).
        if (from != address(0) && to != address(0)) {
            if (redeemed[tokenId]) revert TransferNotAllowed();
            if (block.timestamp >= eventDate) revert TransferNotAllowed();

            // Solo el organizador o un operator con MARKET_ROLE puede transferir.
            bool authorized =
                auth == organizer ||
                hasRole(MARKET_ROLE, auth) ||
                (auth == address(0) && (from == organizer || hasRole(MARKET_ROLE, from)));

            if (!authorized) revert TransferNotAllowed();
        }

        return super._update(to, tokenId, auth);
    }

    // -----------------------------------------------------------------
    // Herencia múltiple: supportsInterface
    // -----------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Royalty, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
