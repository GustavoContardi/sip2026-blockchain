// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {EventFactory} from "./EventFactory.sol";
import {EventNFT} from "./EventNFT.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";

/// @dev Interfaz mínima para leer el estado de cancelación desde OfferingNFT
///      sin importar el contrato completo y su cadena de dependencias.
interface IOfferingNFT {
    function eventCancelled(address eventNFT) external view returns (bool);
}

/**
 * @title NFTMarketplace
 * @notice Mercado secundario de entradas con soporte para pagos en USDC y VBK.
 *         Único canal autorizado de reventa (los EventNFT bloquean transfers P2P).
 *
 *         Invariantes que enforza:
 *           - Precio listado ≤ tope de reventa del evento (originalPrice * maxResalePriceBps).
 *           - No se lista ni se vende post-redeem o post-eventDate.
 *           - No se lista ni se vende si el evento fue cancelado.
 *           - Royalty al organizador configurada por evento, vía EIP-2981 (royaltyInfo).
 *           - Fee de plataforma configurable por token de pago (tope 20%).
 *
 *         La publicación se nomina en USDC para mitigar volatilidad, pero la
 *         ejecución de compra permite procesar el pago en USDC o VBK.
 *
 *         Cancelación: cuando la plataforma llama `cancelEvent` en OfferingNFT,
 *         este contrato lo detecta al momento de listar o comprar leyendo
 *         OfferingNFT.eventCancelled vía factory.offering(). Los listings activos
 *         preexistentes quedan bloqueados sin necesidad de iterarlos.
 */
contract NFTMarketplace is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    EventFactory public immutable factory;
    IERC20 public immutable usdc;
    IERC20 public immutable vbk;
    IUniswapV2Router02 public immutable router;
    address public immutable treasury;

    uint16 public resaleFeeBpsUSDC = 700;       // 7%
    uint16 public resaleFeeBpsVBK  = 400;       // 4%
    /// @notice Fee de plataforma cobrado al donante en transferencias de regalo (sobre originalPrice).
    uint16 public giftFeeBps      = 500;        // 5%
    /// @notice Royalty al organizador cobrado al donante en transferencias de regalo (sobre originalPrice).
    uint16 public giftRoyaltyBps  = 500;        // 5%
    uint16 public constant MAX_FEE_BPS = 2000;  // tope 20%

    struct Listing {
        address seller;
        address eventNFT;
        uint256 tokenId;
        uint256 priceUSDC;
        bool active;
    }

    uint256 public nextListingId;
    mapping(uint256 => Listing) public listings;

    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        address indexed eventNFT,
        uint256 tokenId,
        uint256 priceUSDC
    );
    event Cancelled(uint256 indexed listingId);
    event TicketResoldUSDC(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 amountPaid,
        uint256 royaltyPaid,
        uint256 feePaid
    );
    event TicketResoldVBK(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 vbkPaid,
        uint256 royaltyPaid,
        uint256 vbkFee,
        uint256 priceUSDC
    );
    event ResaleFeeUSDCUpdated(uint16 previous, uint16 next);
    event ResaleFeeVBKUpdated(uint16 previous, uint16 next);

    error UnknownEvent();
    error NotOwner();
    error EventOver();
    error EventCancelled();
    error AlreadyRedeemed();
    error PriceAboveCap(uint256 priceUSDC, uint256 cap);
    error ListingInactive();
    error NotSeller();
    error FeeAboveMax();
    error ZeroAddress();
    error SlippageTooHigh(uint256 quoted, uint256 max);

    event TicketGifted(
        address indexed eventNFT,
        uint256 indexed tokenId,
        address indexed from,
        address     to,
        uint256     originalPrice,
        uint256     feePaid,
        uint256     royaltyPaid
    );
    event GiftFeeUpdated(uint16 oldFee, uint16 newFee);
    event GiftRoyaltyUpdated(uint16 oldBps, uint16 newBps);

    constructor(
        address owner_,
        EventFactory factory_,
        address treasury_
    ) Ownable(owner_) {
        if (address(factory_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        factory = factory_;
        treasury = treasury_;
        usdc = IERC20(factory_.usdc());
        vbk = IERC20(factory_.vbk());
        router = IUniswapV2Router02(factory_.router());
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function setResaleFeeUSDC(uint16 newFee) external onlyOwner {
        if (newFee > MAX_FEE_BPS) revert FeeAboveMax();
        emit ResaleFeeUSDCUpdated(resaleFeeBpsUSDC, newFee);
        resaleFeeBpsUSDC = newFee;
    }

    function setResaleFeeVBK(uint16 newFee) external onlyOwner {
        if (newFee > MAX_FEE_BPS) revert FeeAboveMax();
        emit ResaleFeeVBKUpdated(resaleFeeBpsVBK, newFee);
        resaleFeeBpsVBK = newFee;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -----------------------------------------------------------------
    // Helpers internos
    // -----------------------------------------------------------------

    /// @dev Revierte si el evento fue cancelado por la plataforma.
    ///      Lee el flag desde OfferingNFT vía factory.offering() en cada call:
    ///      - factory.offering() es inmutable post-setOffering (one-shot en factory).
    ///      - No almacena estado adicional en este contrato; la fuente de verdad
    ///        es OfferingNFT, evitando inconsistencias entre contratos.
    function _requireNotCancelled(address eventNFT) internal view {
        if (IOfferingNFT(factory.offering()).eventCancelled(eventNFT)) revert EventCancelled();
    }

    // -----------------------------------------------------------------
    // Listar / Cancelar
    // -----------------------------------------------------------------

    /**
     * @notice Lista un NFT para reventa. Requiere approve previo del NFT al marketplace.
     *         Bloqueado si el evento fue cancelado.
     */
    function list(address eventNFT, uint256 tokenId, uint256 priceUSDC)
        external
        whenNotPaused
        returns (uint256 listingId)
    {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        _requireNotCancelled(eventNFT);

        EventNFT evt = EventNFT(eventNFT);
        if (evt.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (evt.redeemed(tokenId)) revert AlreadyRedeemed();
        if (block.timestamp >= evt.eventDate()) revert EventOver();

        uint256 cap = evt.maxResalePrice(tokenId);
        if (priceUSDC > cap) revert PriceAboveCap(priceUSDC, cap);

        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            eventNFT: eventNFT,
            tokenId: tokenId,
            priceUSDC: priceUSDC,
            active: true
        });
        emit Listed(listingId, msg.sender, eventNFT, tokenId, priceUSDC);
    }

    /// @notice Cancela un listing. El seller puede deslistarse en cualquier momento,
    ///         incluyendo después de que el evento sea cancelado.
    function cancel(uint256 listingId) external {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingInactive();
        if (l.seller != msg.sender) revert NotSeller();
        l.active = false;
        emit Cancelled(listingId);
    }

    // -----------------------------------------------------------------
    // Comprar con USDC (7% fee de plataforma)
    // -----------------------------------------------------------------

    function buyWithUSDC(uint256 listingId) external nonReentrant whenNotPaused {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingInactive();
        _requireNotCancelled(l.eventNFT);

        EventNFT evt = EventNFT(l.eventNFT);
        if (evt.redeemed(l.tokenId)) revert AlreadyRedeemed();
        if (block.timestamp >= evt.eventDate()) revert EventOver();

        uint256 priceUSDC = l.priceUSDC;

        (address royaltyReceiver, uint256 royalty) =
            IERC2981(l.eventNFT).royaltyInfo(l.tokenId, priceUSDC);

        // Fee se cobra ENCIMA del precio listado (lo paga el comprador).
        // Royalty se descuenta del precio listado (lo absorbe el vendedor).
        // Comprador paga: priceUSDC + fee
        // Vendedor recibe: priceUSDC - royalty
        uint256 fee = (priceUSDC * resaleFeeBpsUSDC) / 10_000;
        uint256 sellerProceeds = priceUSDC - royalty;

        l.active = false; // CEI

        if (fee > 0) {
            usdc.safeTransferFrom(msg.sender, treasury, fee);
        }
        if (royalty > 0 && royaltyReceiver != address(0)) {
            usdc.safeTransferFrom(msg.sender, royaltyReceiver, royalty);
        }
        usdc.safeTransferFrom(msg.sender, l.seller, sellerProceeds);

        IERC721(l.eventNFT).safeTransferFrom(l.seller, msg.sender, l.tokenId);

        emit TicketResoldUSDC(listingId, msg.sender, l.seller, priceUSDC, royalty, fee);
    }

    // -----------------------------------------------------------------
    // Comprar con VBK (4% fee de plataforma)
    // -----------------------------------------------------------------

    function buyWithVBK(uint256 listingId, uint256 maxVbkAmount) external nonReentrant whenNotPaused {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingInactive();
        _requireNotCancelled(l.eventNFT);

        EventNFT evt = EventNFT(l.eventNFT);
        if (evt.redeemed(l.tokenId)) revert AlreadyRedeemed();
        if (block.timestamp >= evt.eventDate()) revert EventOver();

        uint256 priceUSDC = l.priceUSDC;

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(vbk);
        uint256[] memory amounts = router.getAmountsOut(priceUSDC, path);
        uint256 vbkNeeded = amounts[1];

        if (vbkNeeded > maxVbkAmount) revert SlippageTooHigh(vbkNeeded, maxVbkAmount);

        (address royaltyReceiver, uint256 royaltyVBK) =
            IERC2981(l.eventNFT).royaltyInfo(l.tokenId, vbkNeeded);

        // Fee se cobra ENCIMA del equivalente VBK (lo paga el comprador).
        // Royalty se descuenta del equivalente VBK (lo absorbe el vendedor).
        // Comprador paga: vbkNeeded + feeVBK
        // Vendedor recibe: vbkNeeded - royaltyVBK
        uint256 feeVBK = (vbkNeeded * resaleFeeBpsVBK) / 10_000;
        uint256 sellerProceedsVBK = vbkNeeded - royaltyVBK;

        l.active = false; // CEI

        if (feeVBK > 0) {
            vbk.safeTransferFrom(msg.sender, treasury, feeVBK);
        }
        if (royaltyVBK > 0 && royaltyReceiver != address(0)) {
            vbk.safeTransferFrom(msg.sender, royaltyReceiver, royaltyVBK);
        }
        vbk.safeTransferFrom(msg.sender, l.seller, sellerProceedsVBK);

        IERC721(l.eventNFT).safeTransferFrom(l.seller, msg.sender, l.tokenId);

        emit TicketResoldVBK(listingId, msg.sender, l.seller, vbkNeeded, royaltyVBK, feeVBK, priceUSDC);
    }

    // -----------------------------------------------------------------
    // Configuración de fees de regalo (onlyOwner)
    // -----------------------------------------------------------------

    function setGiftFee(uint16 newFee) external onlyOwner {
        if (newFee > MAX_FEE_BPS) revert FeeAboveMax();
        emit GiftFeeUpdated(giftFeeBps, newFee);
        giftFeeBps = newFee;
    }

    function setGiftRoyalty(uint16 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeAboveMax();
        emit GiftRoyaltyUpdated(giftRoyaltyBps, newBps);
        giftRoyaltyBps = newBps;
    }

    // -----------------------------------------------------------------
    // Regalar entrada
    // -----------------------------------------------------------------

    /**
     * @notice Transfiere una entrada como regalo.
     *         El donante paga en USDC:
     *           - giftFeeBps     del originalPrice → treasury (fee de plataforma)
     *           - giftRoyaltyBps del originalPrice → organizer del evento
     *         Requiere approve previo al marketplace tanto del NFT
     *         como del monto USDC correspondiente (fee + royalty).
     *
     * Los fees garantizan que la plataforma y el organizador cobren
     * aunque no haya precio de reventa de por medio.
     *
     * @param eventNFT  Address del contrato EventNFT.
     * @param tokenId   Token a regalar.
     * @param recipient Destinatario del regalo (no puede ser address(0)).
     */
    function giftTicket(
        address eventNFT,
        uint256 tokenId,
        address recipient
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        _requireNotCancelled(eventNFT);

        EventNFT evt = EventNFT(eventNFT);
        if (evt.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (evt.redeemed(tokenId)) revert AlreadyRedeemed();
        if (block.timestamp >= evt.eventDate()) revert EventOver();

        // Los fees se calculan sobre el precio original de la venta primaria (en USDC).
        // Se cobra siempre en USDC independientemente de cómo se compró el ticket.
        uint256 originalPrice = evt.originalPrice(tokenId);
        uint256 fee     = (originalPrice * giftFeeBps)     / 10_000;
        uint256 royalty = (originalPrice * giftRoyaltyBps) / 10_000;
        address organizer = evt.organizer();

        // El donante paga fee + royalty en USDC antes de la transferencia del NFT.
        if (fee > 0)     usdc.safeTransferFrom(msg.sender, treasury,  fee);
        if (royalty > 0) usdc.safeTransferFrom(msg.sender, organizer, royalty);

        // Transferencia del NFT: marketplace tiene MARKET_ROLE en EventNFT.
        IERC721(eventNFT).safeTransferFrom(msg.sender, recipient, tokenId);

        emit TicketGifted(eventNFT, tokenId, msg.sender, recipient, originalPrice, fee, royalty);
    }

    // -----------------------------------------------------------------
    // Lectura
    // -----------------------------------------------------------------

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }
}
