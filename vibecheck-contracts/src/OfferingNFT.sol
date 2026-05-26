// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {EventFactory} from "./EventFactory.sol";
import {EventNFT} from "./EventNFT.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";

/**
 * @title OfferingNFT
 * @notice Venta primaria de entradas. Cada compra acuña un nuevo NFT en el EventNFT
 *         correspondiente. Acepta dos medios de pago:
 *
 *           - USDC: precio nominal, fee plataforma del 5% (configurable).
 *           - VBK : precio equivalente vía pool Uniswap V2 (USDC → VBK),
 *                   fee plataforma del 2% (configurable). El descuento de 3%
 *                   lo absorbe la plataforma (menos ingresos por incentivo).
 *
 *         Distribución de cada venta:
 *           - fee plataforma → treasury
 *           - resto          → organizador del evento
 *           - NFT            → comprador
 *
 *         Slippage protection:
 *           - El comprador en VBK provee `maxVbkAmount`. Si el pool se mueve en
 *             contra entre la simulación del frontend y la ejecución on-chain,
 *             la tx revierte. Esto mitiga front-running básico.
 */
contract OfferingNFT is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    EventFactory public immutable factory;
    IERC20 public immutable usdc;
    IERC20 public immutable vbk;
    IUniswapV2Router02 public immutable router;
    address public immutable treasury;

    uint16 public platformFeeBpsUSDC = 500;  // 5%
    uint16 public platformFeeBpsVBK  = 200;  // 2% — descuento implícito de 3% por usar VBK
    uint16 public constant MAX_FEE_BPS = 1000; // 10%

    event TicketPurchasedUSDC(
        address indexed buyer,
        address indexed eventNFT,
        uint256 indexed tokenId,
        uint256 tierIdx,
        uint256 amountPaid,
        uint256 feePaid
    );
    event TicketPurchasedVBK(
        address indexed buyer,
        address indexed eventNFT,
        uint256 indexed tokenId,
        uint256 tierIdx,
        uint256 vbkPaid,
        uint256 vbkFee,
        uint256 priceUSDC
    );
    event PlatformFeeUSDCUpdated(uint16 previous, uint16 next);
    event PlatformFeeVBKUpdated(uint16 previous, uint16 next);

    error UnknownEvent();
    error FeeAboveMax();
    error SlippageTooHigh(uint256 quoted, uint256 max);
    error TierOutOfRange();
    error ZeroAddress();

    constructor(
        address owner_,
        EventFactory factory_,
        address treasury_
    ) Ownable(owner_) {
        if (address(factory_) == address(0) || treasury_ == address(0)) revert ZeroAddress();

        factory = factory_;
        treasury = treasury_;

        // Lee los tokens y el router del factory (single source of truth)
        usdc = IERC20(factory_.usdc());
        vbk = IERC20(factory_.vbk());
        router = IUniswapV2Router02(factory_.router());
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function setPlatformFeeUSDC(uint16 newFee) external onlyOwner {
        if (newFee > MAX_FEE_BPS) revert FeeAboveMax();
        emit PlatformFeeUSDCUpdated(platformFeeBpsUSDC, newFee);
        platformFeeBpsUSDC = newFee;
    }

    function setPlatformFeeVBK(uint16 newFee) external onlyOwner {
        if (newFee > MAX_FEE_BPS) revert FeeAboveMax();
        emit PlatformFeeVBKUpdated(platformFeeBpsVBK, newFee);
        platformFeeBpsVBK = newFee;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -----------------------------------------------------------------
    // Compra con USDC
    // -----------------------------------------------------------------

    function buyWithUSDC(address eventNFT, uint256 tierIdx)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();

        EventNFT evt = EventNFT(eventNFT);
        if (tierIdx >= evt.tiersLength()) revert TierOutOfRange();

        (, uint256 priceUSDC, ,) = evt.tiers(tierIdx);

        uint256 fee = (priceUSDC * platformFeeBpsUSDC) / 10_000;
        uint256 netToOrg = priceUSDC - fee;

        if (fee > 0) usdc.safeTransferFrom(msg.sender, treasury, fee);
        usdc.safeTransferFrom(msg.sender, evt.organizer(), netToOrg);

        tokenId = evt.mintTicket(msg.sender, tierIdx, priceUSDC);

        emit TicketPurchasedUSDC(msg.sender, eventNFT, tokenId, tierIdx, priceUSDC, fee);
    }

    // -----------------------------------------------------------------
    // Compra con VBK (precio dinámico via pool Uniswap V2)
    // -----------------------------------------------------------------

    /**
     * @notice Compra un ticket pagando en VBK.
     * @param eventNFT      address del EventNFT del evento
     * @param tierIdx       índice del tier
     * @param maxVbkAmount  tope de VBK que el comprador acepta pagar (slippage)
     */
    function buyWithVBK(address eventNFT, uint256 tierIdx, uint256 maxVbkAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();

        EventNFT evt = EventNFT(eventNFT);
        if (tierIdx >= evt.tiersLength()) revert TierOutOfRange();

        (, uint256 priceUSDC, ,) = evt.tiers(tierIdx);

        // Cotización dinámica: ¿cuántos VBK necesito para obtener priceUSDC?
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(vbk);
        uint256[] memory amounts = router.getAmountsOut(priceUSDC, path);
        uint256 vbkNeeded = amounts[1];

        if (vbkNeeded > maxVbkAmount) revert SlippageTooHigh(vbkNeeded, maxVbkAmount);

        uint256 fee = (vbkNeeded * platformFeeBpsVBK) / 10_000;
        uint256 netToOrg = vbkNeeded - fee;

        if (fee > 0) vbk.safeTransferFrom(msg.sender, treasury, fee);
        vbk.safeTransferFrom(msg.sender, evt.organizer(), netToOrg);

        // `paidUSDC` que se guarda en el NFT es el precio NOMINAL en USDC.
        // Esto fija la referencia para el tope de reventa, independiente
        // de las fluctuaciones del pool VBK/USDC.
        tokenId = evt.mintTicket(msg.sender, tierIdx, priceUSDC);

        emit TicketPurchasedVBK(msg.sender, eventNFT, tokenId, tierIdx, vbkNeeded, fee, priceUSDC);
    }

    // -----------------------------------------------------------------
    // Helpers de lectura (UX)
    // -----------------------------------------------------------------

    /// @notice Cuántos VBK se necesitan ahora para comprar este tier.
    ///         Útil para el frontend antes de pedir approve.
    function quoteVBK(address eventNFT, uint256 tierIdx) external view returns (uint256) {
        EventNFT evt = EventNFT(eventNFT);
        (, uint256 priceUSDC, ,) = evt.tiers(tierIdx);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(vbk);
        uint256[] memory amounts = router.getAmountsOut(priceUSDC, path);
        return amounts[1];
    }
}
