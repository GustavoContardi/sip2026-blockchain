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

/**
 * @title NFTMarketplace
 * @notice Mercado secundario de entradas. Único canal autorizado de reventa
 *         (los EventNFT bloquean transfers P2P salvo desde MARKET_ROLE).
 *
 *         Invariantes que enforza:
 *           - Precio listado ≤ tope de reventa del tier (originalPrice * tier.maxResalePriceBps).
 *           - No se lista ni se vende post-redeem.
 *           - No se lista ni se vende post-eventDate.
 *           - Royalty 5% al organizador, vía EIP-2981 (royaltyInfo).
 *           - Fee 10% al treasury de la plataforma (configurable hasta 20%).
 *
 *         Pagos exclusivamente en USDC (precio del ticket está denominado en USDC).
 */
contract NFTMarketplace is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    EventFactory public immutable factory;
    IERC20 public immutable usdc;
    address public immutable treasury;

    uint16 public resaleFeeBps = 1000;          // 10%
    uint16 public constant MAX_FEE_BPS = 2000;  // 20%

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
    event Sold(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 priceUSDC,
        uint256 royaltyPaid,
        uint256 feePaid,
        uint256 sellerProceeds
    );
    event ResaleFeeUpdated(uint16 previous, uint16 next);

    error UnknownEvent();
    error NotOwner();
    error EventOver();
    error AlreadyRedeemed();
    error PriceAboveCap(uint256 priceUSDC, uint256 cap);
    error ListingInactive();
    error NotSeller();
    error FeeAboveMax();
    error ZeroAddress();

    constructor(
        address owner_,
        EventFactory factory_,
        address treasury_
    ) Ownable(owner_) {
        if (address(factory_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        factory = factory_;
        treasury = treasury_;
        usdc = IERC20(factory_.usdc());
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function setResaleFee(uint16 newFee) external onlyOwner {
        if (newFee > MAX_FEE_BPS) revert FeeAboveMax();
        emit ResaleFeeUpdated(resaleFeeBps, newFee);
        resaleFeeBps = newFee;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -----------------------------------------------------------------
    // Listar / Cancelar
    // -----------------------------------------------------------------

    /**
     * @notice Lista un NFT para reventa. Requiere approve previo del NFT al marketplace.
     * @dev El marketplace NO custodia el NFT; queda en la wallet del seller hasta la venta.
     */
    function list(address eventNFT, uint256 tokenId, uint256 priceUSDC)
        external
        whenNotPaused
        returns (uint256 listingId)
    {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();

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

    function cancel(uint256 listingId) external {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingInactive();
        if (l.seller != msg.sender) revert NotSeller();
        l.active = false;
        emit Cancelled(listingId);
    }

    // -----------------------------------------------------------------
    // Comprar
    // -----------------------------------------------------------------

    function buy(uint256 listingId) external nonReentrant whenNotPaused {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingInactive();

        EventNFT evt = EventNFT(l.eventNFT);

        // Defense in depth: re-check de invariantes (el seller pudo haber usado el ticket).
        if (evt.redeemed(l.tokenId)) revert AlreadyRedeemed();
        if (block.timestamp >= evt.eventDate()) revert EventOver();

        uint256 priceUSDC = l.priceUSDC;

        // Royalty vía EIP-2981
        (address royaltyReceiver, uint256 royalty) =
            IERC2981(l.eventNFT).royaltyInfo(l.tokenId, priceUSDC);

        uint256 fee = (priceUSDC * resaleFeeBps) / 10_000;
        uint256 sellerProceeds = priceUSDC - royalty - fee;

        // Marca el listing inactivo antes de las transferencias (checks-effects-interactions).
        l.active = false;

        if (royalty > 0 && royaltyReceiver != address(0)) {
            usdc.safeTransferFrom(msg.sender, royaltyReceiver, royalty);
        }
        if (fee > 0) {
            usdc.safeTransferFrom(msg.sender, treasury, fee);
        }
        usdc.safeTransferFrom(msg.sender, l.seller, sellerProceeds);

        // Transferencia del NFT. El marketplace tiene MARKET_ROLE en el EventNFT,
        // por lo que el `_update` del EventNFT autoriza esta transferencia.
        IERC721(l.eventNFT).safeTransferFrom(l.seller, msg.sender, l.tokenId);

        emit Sold(listingId, msg.sender, priceUSDC, royalty, fee, sellerProceeds);
    }

    // -----------------------------------------------------------------
    // Lectura
    // -----------------------------------------------------------------

    /// @notice Snapshot de una listing.
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }
}
