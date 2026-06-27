// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @notice Interfaz mínima del EventNFT que el marketplace necesita consultar.
 */
interface IEventNFT is IERC721, IERC2981 {
    function redeemed(uint256 tokenId) external view returns (bool);
    function attended(uint256 tokenId) external view returns (bool);
    function organizer() external view returns (address);
    function eventDate() external view returns (uint256);
}

/**
 * @notice Interfaz mínima del EventFactory para verificar que un contrato
 *         es un EventNFT legítimo del sistema VibeCheck.
 */
interface IEventFactory {
    function isEvent(address eventNFT) external view returns (bool);
}

/**
 * @notice Interfaz mínima del router Uniswap V2 para cotizar VBK.
 *         El marketplace SOLO cotiza; no hace swap.
 */
interface IUniswapV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);
}

/**
 * @title CollectibleMarketplace
 * @notice Mercado secundario para entradas NFT de eventos que ya ocurrieron.
 *
 *         Una vez que un fan asistió a un evento y su NFT fue marcado como
 *         `redeemed`, la entrada se convierte en un coleccionable digital.
 *         Este contrato permite listarlo, venderlo y comprarlo, preservando
 *         el historial on-chain del show al que representa.
 *
 *         Diferencias clave respecto a NFTMarketplace (pre-evento):
 *         - Exige `redeemed == true` para listar (solo coleccionables).
 *         - No enforza tope de precio: el mercado determina el valor del recuerdo.
 *         - No verifica `!eventCancelled` ni `block.timestamp < eventDate`
 *           (el evento ya pasó por definición).
 *         - No toca el escrow del organizador (ya fue liberado post-evento).
 *
 *         Estructura de fees igual que NFTMarketplace:
 *         - USDC: 7% fee plataforma + royalty EIP-2981 (5% al organizador).
 *         - VBK:  4% fee plataforma + royalty EIP-2981 (5% al organizador).
 *
 *         El royalty se obtiene del contrato EIP-2981 del EventNFT, igual que
 *         en el marketplace pre-evento, garantizando que el organizador siga
 *         capturando valor de cada transacción del coleccionable.
 *
 * @dev Requiere MARKET_ROLE en cada EventNFT para poder transferir tokens.
 *      EventNFT v2 permite que MARKET_ROLE mueva tokens redeemed.
 */
contract CollectibleMarketplace is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Constantes de fees (en bps)
    // -----------------------------------------------------------------

    uint16 public constant FEE_USDC_BPS = 700;  // 7%
    uint16 public constant FEE_VBK_BPS  = 400;  // 4%
    uint16 public constant BPS_BASE     = 10_000;

    // -----------------------------------------------------------------
    // Infraestructura
    // -----------------------------------------------------------------

    IEventFactory       public immutable factory;
    IERC20              public immutable usdc;
    IERC20              public immutable vbk;
    IUniswapV2Router    public immutable router;
    address             public immutable treasury;

    // Dirección del USDC en el path de cotización VBK.
    address private immutable _usdcAddr;
    address private immutable _vbkAddr;

    // -----------------------------------------------------------------
    // Listings
    // -----------------------------------------------------------------

    struct Listing {
        address seller;
        address eventNFT;
        uint256 tokenId;
        uint256 priceUSDC;  // precio en USDC (6 decimales). Base para cotización VBK.
        bool    active;
        uint256 listedAt;   // timestamp del listing (referencia off-chain)
    }

    uint256 private _nextListingId;
    mapping(uint256 => Listing) public listings;

    // Índice rápido: eventNFT → lista de listingIds activos (para UI).
    // Se actualiza en list() y se limpia en _settle() / cancelListing().
    mapping(address => uint256[]) private _listingsByEvent;

    // -----------------------------------------------------------------
    // Eventos
    // -----------------------------------------------------------------

    event CollectibleListed(
        uint256 indexed listingId,
        address indexed eventNFT,
        uint256 indexed tokenId,
        address seller,
        uint256 priceUSDC
    );

    event CollectibleSold(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed eventNFT,
        uint256 tokenId,
        uint256 priceUSDC,
        uint256 royaltyPaid,
        uint256 feePaid,
        bool    paidInVBK
    );

    event CollectibleDelisted(
        uint256 indexed listingId,
        address indexed seller
    );

    event PriceUpdated(
        uint256 indexed listingId,
        uint256 oldPriceUSDC,
        uint256 newPriceUSDC
    );

    // -----------------------------------------------------------------
    // Errores
    // -----------------------------------------------------------------

    error NotAVibeCheckEvent();
    error TokenNotRedeemed();
    error NotTokenOwner();
    error ListingNotActive();
    error NotSeller();
    error SlippageTooHigh();
    error ZeroPrice();
    error ZeroAddress();
    error SamePrice();

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    /**
     * @param factory_   Dirección del EventFactory de VibeCheck.
     * @param usdc_      USDC (ERC-20, 6 decimales).
     * @param vbk_       VBK token (ERC-20).
     * @param router_    Router Uniswap V2 (solo para cotización).
     * @param treasury_  Wallet que recibe los fees de plataforma.
     * @param admin_     Owner del contrato (plataforma).
     */
    constructor(
        address factory_,
        address usdc_,
        address vbk_,
        address router_,
        address treasury_,
        address admin_
    ) Ownable(admin_) {
        if (
            factory_  == address(0) ||
            usdc_     == address(0) ||
            vbk_      == address(0) ||
            router_   == address(0) ||
            treasury_ == address(0) ||
            admin_    == address(0)
        ) revert ZeroAddress();

        factory  = IEventFactory(factory_);
        usdc     = IERC20(usdc_);
        vbk      = IERC20(vbk_);
        router   = IUniswapV2Router(router_);
        treasury = treasury_;

        _usdcAddr = usdc_;
        _vbkAddr  = vbk_;
    }

    // -----------------------------------------------------------------
    // Listar coleccionable
    // -----------------------------------------------------------------

    /**
     * @notice Publica un coleccionable (entrada redeemed) en el marketplace.
     * @param eventNFT   Contrato del evento al que pertenece la entrada.
     * @param tokenId    ID del token a listar.
     * @param priceUSDC  Precio de venta en USDC (6 decimales).
     *
     * @dev El vendedor debe haber llamado `EventNFT.approve(address(this), tokenId)`
     *      o `EventNFT.setApprovalForAll(address(this), true)` antes.
     */
    function list(address eventNFT, uint256 tokenId, uint256 priceUSDC)
        external
        whenNotPaused
        returns (uint256 listingId)
    {
        if (!factory.isEvent(eventNFT)) revert NotAVibeCheckEvent();
        if (priceUSDC == 0) revert ZeroPrice();

        IEventNFT nft = IEventNFT(eventNFT);

        // Solo coleccionables (tokens que ya fueron al evento).
        if (!nft.redeemed(tokenId)) revert TokenNotRedeemed();

        // El que lista debe ser el dueño actual.
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        listingId = ++_nextListingId;

        listings[listingId] = Listing({
            seller:    msg.sender,
            eventNFT:  eventNFT,
            tokenId:   tokenId,
            priceUSDC: priceUSDC,
            active:    true,
            listedAt:  block.timestamp
        });

        _listingsByEvent[eventNFT].push(listingId);

        emit CollectibleListed(listingId, eventNFT, tokenId, msg.sender, priceUSDC);
    }

    // -----------------------------------------------------------------
    // Comprar con USDC
    // -----------------------------------------------------------------

    /**
     * @notice Compra un coleccionable pagando en USDC.
     * @param listingId  ID del listing.
     *
     * @dev El comprador debe haber aprobado USDC al contrato por al menos
     *      `listings[listingId].priceUSDC` antes de llamar.
     */
    function buyWithUSDC(uint256 listingId)
        external
        nonReentrant
        whenNotPaused
    {
        Listing storage l = _requireActiveListing(listingId);
        _settle(listingId, l, msg.sender, false, 0);
    }

    // -----------------------------------------------------------------
    // Comprar con VBK
    // -----------------------------------------------------------------

    /**
     * @notice Cotiza cuántos VBK necesita el comprador para este listing.
     * @param listingId  ID del listing.
     * @return vbkNeeded Cantidad de VBK equivalente al priceUSDC del listing.
     */
    function quoteVBK(uint256 listingId) external view returns (uint256 vbkNeeded) {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingNotActive();
        vbkNeeded = _quoteVBK(l.priceUSDC);
    }

    /**
     * @notice Compra un coleccionable pagando en VBK.
     * @param listingId     ID del listing.
     * @param maxVbkAmount  Máximo de VBK que el comprador acepta pagar (slippage guard).
     *
     * @dev El comprador debe haber aprobado VBK al contrato por al menos
     *      `maxVbkAmount` antes de llamar.
     */
    function buyWithVBK(uint256 listingId, uint256 maxVbkAmount)
        external
        nonReentrant
        whenNotPaused
    {
        Listing storage l = _requireActiveListing(listingId);

        uint256 vbkNeeded = _quoteVBK(l.priceUSDC);
        if (vbkNeeded > maxVbkAmount) revert SlippageTooHigh();

        _settle(listingId, l, msg.sender, true, vbkNeeded);
    }

    // -----------------------------------------------------------------
    // Cancelar listing
    // -----------------------------------------------------------------

    /**
     * @notice El vendedor retira su listing del mercado.
     * @param listingId  ID del listing a cancelar.
     */
    function cancelListing(uint256 listingId) external {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingNotActive();
        if (l.seller != msg.sender) revert NotSeller();

        l.active = false;
        emit CollectibleDelisted(listingId, msg.sender);
    }

    // -----------------------------------------------------------------
    // Actualizar precio
    // -----------------------------------------------------------------

    /**
     * @notice El vendedor puede cambiar el precio de su listing activo.
     * @param listingId    ID del listing.
     * @param newPriceUSDC Nuevo precio en USDC (6 decimales).
     */
    function updatePrice(uint256 listingId, uint256 newPriceUSDC) external {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingNotActive();
        if (l.seller != msg.sender) revert NotSeller();
        if (newPriceUSDC == 0) revert ZeroPrice();
        if (newPriceUSDC == l.priceUSDC) revert SamePrice();

        uint256 old = l.priceUSDC;
        l.priceUSDC = newPriceUSDC;
        emit PriceUpdated(listingId, old, newPriceUSDC);
    }

    // -----------------------------------------------------------------
    // Vistas para UI/backend
    // -----------------------------------------------------------------

    /**
     * @notice Devuelve todos los listingIds asociados a un evento.
     *         Incluye activos e inactivos; el front filtra por `active`.
     */
    function listingsByEvent(address eventNFT)
        external view
        returns (uint256[] memory)
    {
        return _listingsByEvent[eventNFT];
    }

    /**
     * @notice Devuelve los datos completos de un listing.
     */
    function getListing(uint256 listingId)
        external view
        returns (Listing memory)
    {
        return listings[listingId];
    }

    /**
     * @notice Total de listings creados (activos + inactivos).
     */
    function totalListings() external view returns (uint256) {
        return _nextListingId;
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -----------------------------------------------------------------
    // Lógica interna
    // -----------------------------------------------------------------

    /**
     * @dev Valida que el listing exista y esté activo. Revierte si no.
     */
    function _requireActiveListing(uint256 listingId)
        internal view
        returns (Listing storage l)
    {
        l = listings[listingId];
        if (!l.active) revert ListingNotActive();
    }

    /**
     * @dev Cotiza VBK equivalente a `priceUSDC` vía el pool Uniswap V2.
     *      Solo lectura; no ejecuta swap.
     */
    function _quoteVBK(uint256 priceUSDC) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = _usdcAddr;
        path[1] = _vbkAddr;
        uint256[] memory amounts = router.getAmountsOut(priceUSDC, path);
        return amounts[1];
    }

    /**
     * @dev Ejecuta el settlement de una venta.
     *      Distribuye: royalty → organizador, fee → treasury, neto → vendedor.
     *      Transfiere el NFT del vendedor al comprador vía MARKET_ROLE.
     *
     *      Patrón CEI: marca listing como inactivo ANTES de las transferencias
     *      de tokens y del safeTransferFrom para evitar reentrancy.
     *
     * @param listingId  ID del listing.
     * @param l          Storage reference del listing.
     * @param buyer      Comprador.
     * @param inVBK      true = pago en VBK, false = pago en USDC.
     * @param vbkAmount  Cantidad de VBK a cobrar (solo si inVBK == true).
     */
    function _settle(
        uint256 listingId,
        Listing storage l,
        address buyer,
        bool inVBK,
        uint256 vbkAmount
    ) internal {
        // --- CEI: desactivar listing antes de cualquier transfer externo ---
        address seller   = l.seller;
        address eventNFT = l.eventNFT;
        uint256 tokenId  = l.tokenId;
        uint256 price    = l.priceUSDC;
        l.active = false;

        // Obtener royalty del organizador vía EIP-2981.
        // royaltyInfo devuelve (receiver, royaltyAmount) para el precio dado.
        // En USDC el precio base es `price`; en VBK es `vbkAmount`.
        uint256 royalty;
        address royaltyReceiver;

        if (inVBK) {
            (royaltyReceiver, royalty) = IERC2981(eventNFT).royaltyInfo(tokenId, vbkAmount);
            uint256 fee = (vbkAmount * FEE_VBK_BPS) / BPS_BASE;
            uint256 net = vbkAmount - royalty - fee;

            // Transferir VBK del comprador al contrato primero (pull pattern).
            vbk.safeTransferFrom(buyer, address(this), vbkAmount);

            // Distribuir.
            if (royalty > 0) vbk.safeTransfer(royaltyReceiver, royalty);
            vbk.safeTransfer(treasury, fee);
            vbk.safeTransfer(seller,   net);

            emit CollectibleSold(
                listingId, buyer, eventNFT, tokenId,
                price, royalty, fee, true
            );
        } else {
            (royaltyReceiver, royalty) = IERC2981(eventNFT).royaltyInfo(tokenId, price);
            uint256 fee = (price * FEE_USDC_BPS) / BPS_BASE;
            uint256 net = price - royalty - fee;

            // Transferir USDC del comprador al contrato.
            usdc.safeTransferFrom(buyer, address(this), price);

            // Distribuir.
            if (royalty > 0) usdc.safeTransfer(royaltyReceiver, royalty);
            usdc.safeTransfer(treasury, fee);
            usdc.safeTransfer(seller,   net);

            emit CollectibleSold(
                listingId, buyer, eventNFT, tokenId,
                price, royalty, fee, false
            );
        }

        // Transferir el NFT. El contrato tiene MARKET_ROLE en EventNFT v2,
        // que permite mover tokens redeemed. El NFT se aprueba al marketplace
        // por el vendedor en el listing; acá lo transferimos al comprador.
        IEventNFT(eventNFT).safeTransferFrom(seller, buyer, tokenId);
    }
}
