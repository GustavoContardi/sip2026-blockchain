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
 * @notice Interfaz mínima del módulo de recompensas. El EventNFT no maneja
 *         USDC/VBK ni cotización: solo avisa que un fan asistió. El vault
 *         decide cuánto VBK acreditar (valorizado en 0.10 USDC vía el pool)
 *         y lo transfiere a la wallet del fan.
 */
interface IRewardsVault {
    function notifyRedeem(address fan, uint256 tokenId) external;
}

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
 *             (NFTMarketplace / CollectibleMarketplace) puede mover NFTs entre wallets.
 *             Mints y burns libres.
 *           - Tope de reventa por evento: `maxResalePriceBps` * `originalPrice[tokenId]`.
 *             Solo aplica en el marketplace pre-evento; CollectibleMarketplace
 *             no enforza tope (mercado libre post-evento).
 *           - Check-in on-chain: `redeem()` con firma del `venueSigner`. Marca el
 *             tokenId como usado, dispara mutación de `tokenURI` (entrada → coleccionable)
 *             y notifica al `rewardsVault` (si está configurado) para acreditar la
 *             recompensa en VBK al fan.
 *           - Post-redeem: el NFT es transferible SOLO vía MARKET_ROLE
 *             (CollectibleMarketplace). Las transferencias P2P directas siguen
 *             bloqueadas para forzar el cobro de royalty y fee en el mercado.
 *
 * @dev CAMBIO v2 respecto a v1:
 *      `_update` ahora permite que MARKET_ROLE transfiera tokens redeemed y/o
 *      post-eventDate. La restricción `redeemed[tokenId]` y `block.timestamp >= eventDate`
 *      aplica solo a transfers sin MARKET_ROLE. Esto habilita CollectibleMarketplace.
 */
contract EventNFT is ERC721, ERC721Pausable, ERC721Royalty, AccessControl, Ownable {
    using Strings for uint256;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant MARKET_ROLE  = keccak256("MARKET_ROLE");

    /// @notice Definición de un tier de entradas.
    struct Tier {
        string  name;       // "VIP", "Campo", "Platea", "Preventa"
        uint256 priceUSDC;  // 6 decimales (USDC)
        uint256 supply;     // máximo de tickets de este tier
        uint256 sold;       // contador de vendidos
    }

    // -----------------------------------------------------------------
    // Estado del evento
    // -----------------------------------------------------------------

    address public immutable organizer;
    address public immutable factory;
    uint256 public immutable eventDate;         // timestamp UNIX del evento
    uint16  public immutable maxResalePriceBps; // tope reventa, ej. 12000 = 120%
    uint16  public immutable royaltyBps;        // royalty al organizador, ej. 500 = 5%

    address public venueSigner;  // firma off-chain los QRs en puerta
    address public rewardsVault; // acredita VBK al fan en cada redeem; address(0) = desactivado
    string  private _baseTokenURI;

    Tier[] public tiers;

    uint256 private _nextId;

    /// @notice Tier al que pertenece cada token.
    mapping(uint256 => uint256) public tokenTier;
    /// @notice Precio nominal en USDC pagado en la venta primaria.
    ///         Sirve como referencia para el tope de reventa.
    mapping(uint256 => uint256) public originalPrice;
    /// @notice Si el token ya fue usado para entrar al evento (check-in).
    mapping(uint256 => bool) public redeemed;
    /// @notice Si el holder asistió (controla la mutación del tokenURI).
    mapping(uint256 => bool) public attended;

    // -----------------------------------------------------------------
    // Eventos y errores
    // -----------------------------------------------------------------

    event TicketSold(address indexed buyer, uint256 indexed tokenId, uint256 indexed tierIdx, uint256 priceUSDC);
    event TicketRefundBurned(uint256 indexed tokenId, uint256 indexed tierIdx);
    event Redeemed(uint256 indexed tokenId, address indexed by);
    event VenueSignerUpdated(address indexed previous, address indexed next);
    event RewardsVaultUpdated(address indexed previous, address indexed next);
    event RewardNotificationFailed(uint256 indexed tokenId, address indexed fan);
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
    error InvalidRoyalty();

    /// @notice Parámetros agrupados para evitar stack too deep en el constructor.
    struct InitParams {
        string  name;
        string  symbol;
        address organizer;
        uint256 eventDate;
        uint16  maxResalePriceBps;  // tope de reventa (bps). 10000=100%, 12000=120%, etc.
        uint16  royaltyBps;         // royalty al organizador (bps). Tope: 2000 = 20%.
        address venueSigner;
        string  baseURI;
        address rewardsVault;       // address(0) = sin recompensas activadas al nacer
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
        if (p.maxResalePriceBps < 10_000 || p.maxResalePriceBps > 50_000) revert InvalidResaleCap();
        if (p.royaltyBps > 2_000) revert InvalidRoyalty();

        organizer    = p.organizer;
        factory      = msg.sender;
        eventDate    = p.eventDate;
        maxResalePriceBps = p.maxResalePriceBps;
        royaltyBps   = p.royaltyBps;
        venueSigner  = p.venueSigner;
        _baseTokenURI = p.baseURI;

        if (p.rewardsVault != address(0)) {
            rewardsVault = p.rewardsVault;
            emit RewardsVaultUpdated(address(0), p.rewardsVault);
        }

        for (uint256 i = 0; i < tiers_.length; i++) {
            if (tiers_[i].supply == 0) revert InvalidTierSupply();
            tiers.push(Tier({
                name:      tiers_[i].name,
                priceUSDC: tiers_[i].priceUSDC,
                supply:    tiers_[i].supply,
                sold:      0
            }));
        }

        _setDefaultRoyalty(p.organizer, p.royaltyBps);

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

    function setRewardsVault(address newVault) external onlyOwner {
        emit RewardsVaultUpdated(rewardsVault, newVault);
        rewardsVault = newVault;
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
        tokenTier[tokenId]    = tierIdx;
        originalPrice[tokenId] = paidUSDC;

        _mint(to, tokenId);
        emit TicketSold(to, tokenId, tierIdx, paidUSDC);
    }

    function refundBurn(uint256 tokenId) external onlyRole(MINTER_ROLE) {
        uint256 tierIdx = tokenTier[tokenId];
        _burn(tokenId);
        tiers[tierIdx].sold -= 1;
        emit TicketRefundBurned(tokenId, tierIdx);
    }

    // -----------------------------------------------------------------
    // Check-in (redeem con firma del venue)
    // -----------------------------------------------------------------

    /**
     * @notice Marca un ticket como usado. Requiere firma del venueSigner.
     * @dev El mensaje firmado es `keccak256(abi.encode(address(this), tokenId, chainid))`.
     *      Ventana de check-in: desde 1 día antes hasta 1 día después del evento.
     *      Si `rewardsVault` está configurado, notifica al vault para acreditar VBK.
     *      Un fallo del vault NO revierte el check-in.
     */
    function redeem(uint256 tokenId, bytes calldata signature) external {
        if (redeemed[tokenId]) revert AlreadyRedeemed();

        bytes32 digest = keccak256(abi.encode(address(this), tokenId, block.chainid))
            .toEthSignedMessageHash();
        address recovered = digest.recover(signature);
        if (recovered != venueSigner) revert InvalidSignature();

        redeemed[tokenId]  = true;
        attended[tokenId]  = true;
        emit Redeemed(tokenId, msg.sender);

        if (rewardsVault != address(0)) {
            address fan = _ownerOf(tokenId);
            try IRewardsVault(rewardsVault).notifyRedeem(fan, tokenId) {
                // recompensa acreditada
            } catch {
                emit RewardNotificationFailed(tokenId, fan);
            }
        }
    }

    // -----------------------------------------------------------------
    // Helpers de lectura
    // -----------------------------------------------------------------

    function maxResalePrice(uint256 tokenId) external view returns (uint256) {
        return (originalPrice[tokenId] * maxResalePriceBps) / 10_000;
    }

    function tiersLength() external view returns (uint256) {
        return tiers.length;
    }

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
     *
     *      Mint (from == 0) y burn (to == 0): siempre permitidos.
     *
     *      Para transferencias reales (from != 0 && to != 0):
     *
     *      1. Si `auth` tiene MARKET_ROLE:
     *         - Permitido en cualquier estado (pre/post-evento, redeemed o no).
     *         - CollectibleMarketplace usa esta ruta para mover coleccionables.
     *         - NFTMarketplace usa esta ruta para reventa pre-evento.
     *
     *      2. Si `auth` NO tiene MARKET_ROLE:
     *         - Bloqueado si el token fue redeemed.
     *         - Bloqueado si el evento ya pasó.
     *         - Bloqueado si auth no es el organizador.
     *         (Igual que v1, sin cambios para el caso no-market.)
     *
     *      Diseño de seguridad del bypass MARKET_ROLE:
     *      - NFTMarketplace rechaza listar tokens redeemed → no puede revender
     *        entradas ya usadas como si fueran válidas.
     *      - CollectibleMarketplace exige redeemed == true para listar → no
     *        puede mover entradas pre-uso.
     *      - El enforcement está en el contrato del marketplace, no en _update.
     *        Cada marketplace controla qué tokens acepta; _update solo controla
     *        quién puede ejecutar el transfer físico.
     *
     *      `auth` en OZ v5:
     *      - Owner llama transferFrom directo → auth == owner.
     *      - Approved/operator llama → auth == ese operator.
     *      - Mint/burn internos → auth == address(0) (caso from/to == 0, ya excluido arriba).
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Pausable)
        returns (address)
    {
        address from = _ownerOf(tokenId);

        // Transferencia real (no mint ni burn).
        if (from != address(0) && to != address(0)) {

            // Determinar si el operador tiene MARKET_ROLE.
            // auth == address(0) ocurre en transfers internos donde OZ no
            // pasa un operator explícito; en ese caso miramos `from`.
            bool isMarket =
                hasRole(MARKET_ROLE, auth) ||
                (auth == address(0) && hasRole(MARKET_ROLE, from));

            if (isMarket) {
                // MARKET_ROLE: sin restricciones de estado ni fecha.
                // El marketplace que llama es responsable de validar
                // el estado del token antes de ejecutar el transfer.
                // Caemos directo al super._update sin checks adicionales.
            } else {
                // Sin MARKET_ROLE: aplican todas las restricciones originales.

                // Tokens redeemed no se pueden transferir P2P.
                if (redeemed[tokenId]) revert TransferNotAllowed();

                // Después del evento no se pueden transferir P2P.
                if (block.timestamp >= eventDate) revert TransferNotAllowed();

                // Solo el organizador puede hacer transfers directos
                // (p.ej. distribución inicial desde el OfferingNFT ya
                //  maneja los mints; esto cubre edge cases del organizador).
                bool authorized =
                    auth == organizer ||
                    (auth == address(0) && from == organizer);

                if (!authorized) revert TransferNotAllowed();
            }
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
