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
 * @notice Venta primaria de entradas con ESCROW. Cada compra acuña un nuevo NFT
 *         en el EventNFT correspondiente. Acepta dos medios de pago:
 *
 *           - USDC: precio nominal, fee plataforma del 5% (configurable).
 *           - VBK : precio equivalente vía pool Uniswap V2 (USDC → VBK),
 *                   fee plataforma del 2% (configurable).
 *
 *         Distribución de cada venta:
 *           - fee plataforma → treasury (inmediato)
 *           - resto          → ESCROW retenido en este contrato por evento
 *           - NFT            → comprador (inmediato)
 *
 *         El organizador NO cobra al momento de la venta. Los fondos quedan
 *         retenidos en el contrato y solo pueden liberarse llamando a
 *         `releaseEscrow(eventNFT)` DESPUÉS de que pasó la fecha del evento.
 *         Esto protege a los compradores: si el organizador desaparece antes
 *         del evento, no se llevó el dinero.
 *
 *         Slippage protection en VBK: el comprador provee `maxVbkAmount`.
 */
contract OfferingNFT is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    EventFactory public immutable factory;
    IERC20 public immutable usdc;
    IERC20 public immutable vbk;
    IUniswapV2Router02 public immutable router;
    address public immutable treasury;

    uint16 public platformFeeBpsUSDC = 500;  // 5%
    uint16 public platformFeeBpsVBK  = 200;  // 2%
    uint16 public constant MAX_FEE_BPS = 1000; // 10%

    // -----------------------------------------------------------------
    // Escrow: fondos retenidos por evento hasta que el evento se complete
    // -----------------------------------------------------------------
    /// @notice USDC retenido en escrow por evento (eventNFT => monto).
    mapping(address => uint256) public escrowUSDC;
    /// @notice VBK retenido en escrow por evento (eventNFT => monto).
    mapping(address => uint256) public escrowVBK;
    /// @notice Marca si el escrow de un evento ya fue liberado.
    mapping(address => bool) public escrowReleased;

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
    event EscrowReleased(
        address indexed eventNFT,
        address indexed organizer,
        uint256 usdcAmount,
        uint256 vbkAmount
    );
    event PlatformFeeUSDCUpdated(uint16 previous, uint16 next);
    event PlatformFeeVBKUpdated(uint16 previous, uint16 next);

    error UnknownEvent();
    error FeeAboveMax();
    error SlippageTooHigh(uint256 quoted, uint256 max);
    error TierOutOfRange();
    error ZeroAddress();
    error EventNotOver();
    error AlreadyReleased();
    error NothingToRelease();

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
    // Compra con USDC — el neto queda en escrow
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
        uint256 netToEscrow = priceUSDC - fee;

        // Fee va directo al treasury (la plataforma cobra su comisión al instante)
        if (fee > 0) usdc.safeTransferFrom(msg.sender, treasury, fee);
        // El neto del organizador queda retenido en este contrato (escrow)
        usdc.safeTransferFrom(msg.sender, address(this), netToEscrow);
        escrowUSDC[eventNFT] += netToEscrow;

        tokenId = evt.mintTicket(msg.sender, tierIdx, priceUSDC);

        emit TicketPurchasedUSDC(msg.sender, eventNFT, tokenId, tierIdx, priceUSDC, fee);
    }

    // -----------------------------------------------------------------
    // Compra con VBK — el neto queda en escrow
    // -----------------------------------------------------------------

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

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(vbk);
        uint256[] memory amounts = router.getAmountsOut(priceUSDC, path);
        uint256 vbkNeeded = amounts[1];

        if (vbkNeeded > maxVbkAmount) revert SlippageTooHigh(vbkNeeded, maxVbkAmount);

        uint256 fee = (vbkNeeded * platformFeeBpsVBK) / 10_000;
        uint256 netToEscrow = vbkNeeded - fee;

        if (fee > 0) vbk.safeTransferFrom(msg.sender, treasury, fee);
        vbk.safeTransferFrom(msg.sender, address(this), netToEscrow);
        escrowVBK[eventNFT] += netToEscrow;

        tokenId = evt.mintTicket(msg.sender, tierIdx, priceUSDC);

        emit TicketPurchasedVBK(msg.sender, eventNFT, tokenId, tierIdx, vbkNeeded, fee, priceUSDC);
    }

    // -----------------------------------------------------------------
    // Liberación del escrow — solo después de la fecha del evento
    // -----------------------------------------------------------------

    /**
     * @notice Libera los fondos retenidos al organizador del evento.
     *         Solo puede llamarse DESPUÉS de la fecha del evento y solo una vez.
     *         Cualquiera puede disparar la liberación (los fondos siempre van
     *         al organizador), pero típicamente lo hace el propio organizador.
     * @param eventNFT address del EventNFT del evento
     */
    function releaseEscrow(address eventNFT) external nonReentrant {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        if (escrowReleased[eventNFT]) revert AlreadyReleased();

        EventNFT evt = EventNFT(eventNFT);
        if (block.timestamp <= evt.eventDate()) revert EventNotOver();

        uint256 usdcAmount = escrowUSDC[eventNFT];
        uint256 vbkAmount  = escrowVBK[eventNFT];
        if (usdcAmount == 0 && vbkAmount == 0) revert NothingToRelease();

        address organizer = evt.organizer();

        // Marcar como liberado ANTES de transferir (checks-effects-interactions)
        escrowReleased[eventNFT] = true;
        escrowUSDC[eventNFT] = 0;
        escrowVBK[eventNFT]  = 0;

        if (usdcAmount > 0) usdc.safeTransfer(organizer, usdcAmount);
        if (vbkAmount  > 0) vbk.safeTransfer(organizer, vbkAmount);

        emit EscrowReleased(eventNFT, organizer, usdcAmount, vbkAmount);
    }

    // -----------------------------------------------------------------
    // Helpers de lectura (UX)
    // -----------------------------------------------------------------

    /// @notice Cuántos VBK se necesitan ahora para comprar este tier.
    function quoteVBK(address eventNFT, uint256 tierIdx) external view returns (uint256) {
        EventNFT evt = EventNFT(eventNFT);
        (, uint256 priceUSDC, ,) = evt.tiers(tierIdx);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(vbk);
        uint256[] memory amounts = router.getAmountsOut(priceUSDC, path);
        return amounts[1];
    }

    /// @notice Devuelve si el escrow de un evento ya puede liberarse.
    function canRelease(address eventNFT) external view returns (bool) {
        if (!factory.isEvent(eventNFT)) return false;
        if (escrowReleased[eventNFT]) return false;
        EventNFT evt = EventNFT(eventNFT);
        if (block.timestamp <= evt.eventDate()) return false;
        return escrowUSDC[eventNFT] > 0 || escrowVBK[eventNFT] > 0;
    }
}
