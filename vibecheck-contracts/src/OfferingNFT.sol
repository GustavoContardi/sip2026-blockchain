// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {EventFactory} from "./EventFactory.sol";
import {EventNFT} from "./EventNFT.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";

/**
 * @title OfferingNFT
 * @notice Venta primaria de entradas con ESCROW por token. Cada compra acuña un
 *         nuevo NFT en el EventNFT correspondiente y retiene el neto del organizador
 *         en este contrato hasta que el evento se complete.
 *
 *         Medios de pago:
 *           - USDC: precio nominal, fee plataforma 5% (configurable).
 *           - VBK : precio equivalente vía pool Uniswap V2, fee plataforma 2%.
 *
 *         Distribución de cada venta:
 *           - fee plataforma → treasury (inmediato)
 *           - resto          → ESCROW retenido por token en este contrato
 *           - NFT            → comprador (inmediato)
 *
 *         Tres salidas del escrow, mutuamente excluyentes a nivel evento:
 *           1. releaseEscrow(eventNFT): tras eventDate + RELEASE_GRACE, paga el
 *              remanente al organizador. Bloqueado si el evento fue cancelado.
 *           2. cancelEvent(eventNFT) + refundCancelled(eventNFT, tokenId): si la
 *              plataforma cancela, cada holder vigente recupera su escrow.
 *           3. refundVoluntary(...): arrepentimiento del comprador ORIGINAL, hasta
 *              REFUND_CUTOFF antes del evento, autorizado por firma del backend.
 *              Quema la entrada y libera el cupo. El revendedor queda excluido.
 *
 *         Contabilidad por token: el escrow se rastrea por (eventNFT, tokenId).
 *         El agregado por evento (escrowUSDC/escrowVBK) se mantiene como suma de
 *         los tokens aún en escrow, y es lo que paga releaseEscrow.
 */
contract OfferingNFT is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    EventFactory public immutable factory;
    IERC20 public immutable usdc;
    IERC20 public immutable vbk;
    IUniswapV2Router02 public immutable router;
    address public immutable treasury;

    uint16 public platformFeeBpsUSDC = 700;  // 7%
    uint16 public platformFeeBpsVBK  = 400;  // 4%
    uint16 public constant MAX_FEE_BPS = 1000; // 10%

    // -----------------------------------------------------------------
    // Parámetros de reembolso
    // -----------------------------------------------------------------
    /// @notice Gracia tras eventDate antes de poder liberar al organizador.
    uint256 public constant RELEASE_GRACE = 7 days;
    /// @notice Anticipación mínima al evento para permitir reembolso voluntario.
    uint256 public constant REFUND_CUTOFF = 72 hours;
    /// @notice Cargo de reposición en el reembolso voluntario (bps del escrow del token).
    ///         El comprador recibe escrow*(10000-restockFeeBps)/10000; el resto va al treasury.
    ///         El fee de plataforma original (5% USDC / 2% VBK) ya salió y NO se reembolsa.
    uint16 public restockFeeBps = 500; // 5%
    /// @notice Porcentaje del escrow del token que se devuelve en cancelación (bps).
    uint16 public cancelRefundBps = 10_000; // 100% del escrow
    uint16 public constant MAX_RESTOCK_BPS = 2_000; // tope 20%

    /// @notice Firma autorizadora de reembolsos voluntarios (clave en el backend).
    address public refundSigner;

    // -----------------------------------------------------------------
    // Escrow agregado por evento (remanente liberable al organizador)
    // -----------------------------------------------------------------
    mapping(address => uint256) public escrowUSDC;
    mapping(address => uint256) public escrowVBK;
    mapping(address => bool) public escrowReleased;

    // -----------------------------------------------------------------
    // Escrow por token y metadatos de reembolso
    // -----------------------------------------------------------------
    /// @notice USDC retenido por token: eventNFT => tokenId => monto.
    mapping(address => mapping(uint256 => uint256)) public escrowUSDCByToken;
    /// @notice VBK retenido por token: eventNFT => tokenId => monto.
    mapping(address => mapping(uint256 => uint256)) public escrowVBKByToken;
    /// @notice Comprador original (minter) por token. Si revendió, ownerOf deja de
    ///         coincidir y el reembolso voluntario queda deshabilitado solo.
    mapping(address => mapping(uint256 => address)) public originalMinter;
    /// @notice Evento marcado como cancelado por la plataforma.
    mapping(address => bool) public eventCancelled;

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
    event EventCancelledByPlatform(address indexed eventNFT);
    event RefundedVoluntary(
        address indexed eventNFT,
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 usdcToBuyer,
        uint256 vbkToBuyer,
        uint256 usdcRestock,
        uint256 vbkRestock
    );
    event RefundedCancelled(
        address indexed eventNFT,
        uint256 indexed tokenId,
        address indexed holder,
        uint256 usdcAmount,
        uint256 vbkAmount
    );
    event PlatformFeeUSDCUpdated(uint16 previous, uint16 next);
    event PlatformFeeVBKUpdated(uint16 previous, uint16 next);
    event RestockFeeUpdated(uint16 previous, uint16 next);
    event CancelRefundBpsUpdated(uint16 previous, uint16 next);
    event RefundSignerUpdated(address indexed previous, address indexed next);

    error UnknownEvent();
    error FeeAboveMax();
    error SlippageTooHigh(uint256 quoted, uint256 max);
    error TierOutOfRange();
    error ZeroAddress();
    error EventNotOver();
    error AlreadyReleased();
    error NothingToRelease();
    error EventIsCancelled();
    error EventNotCancelled();
    error NotEventHolder();
    error NotOriginalBuyer();
    error TicketRedeemed();
    error RefundWindowClosed();
    error NothingToRefund();
    error SignatureExpired();
    error InvalidRefundSignature();
    error RefundSignerNotSet();
    error BpsAboveMax();

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

    function setRestockFee(uint16 newFee) external onlyOwner {
        if (newFee > MAX_RESTOCK_BPS) revert BpsAboveMax();
        emit RestockFeeUpdated(restockFeeBps, newFee);
        restockFeeBps = newFee;
    }

    function setCancelRefundBps(uint16 newBps) external onlyOwner {
        if (newBps > 10_000) revert BpsAboveMax();
        emit CancelRefundBpsUpdated(cancelRefundBps, newBps);
        cancelRefundBps = newBps;
    }

    function setRefundSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit RefundSignerUpdated(refundSigner, newSigner);
        refundSigner = newSigner;
    }

    /// @notice Cancela un evento. Bloquea releaseEscrow y habilita refundCancelled.
    ///         One-shot implícito vía el flag; no puede cancelarse tras liberar.
    function cancelEvent(address eventNFT) external onlyOwner {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        if (escrowReleased[eventNFT]) revert AlreadyReleased();
        eventCancelled[eventNFT] = true;
        emit EventCancelledByPlatform(eventNFT);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -----------------------------------------------------------------
    // Compra con USDC — el neto queda en escrow (agregado + por token)
    // -----------------------------------------------------------------

    function buyWithUSDC(address eventNFT, uint256 tierIdx)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        if (eventCancelled[eventNFT]) revert EventIsCancelled();

        EventNFT evt = EventNFT(eventNFT);
        if (tierIdx >= evt.tiersLength()) revert TierOutOfRange();

        (, uint256 priceUSDC, ,) = evt.tiers(tierIdx);

        uint256 fee = (priceUSDC * platformFeeBpsUSDC) / 10_000;

        // El fee se cobra ENCIMA del precio nominal.
        // El comprador paga priceUSDC + fee en total.
        // El escrow guarda priceUSDC completo; el organizador no absorbe el fee.
        if (fee > 0) usdc.safeTransferFrom(msg.sender, treasury, fee);
        usdc.safeTransferFrom(msg.sender, address(this), priceUSDC);

        tokenId = evt.mintTicket(msg.sender, tierIdx, priceUSDC);

        escrowUSDC[eventNFT] += priceUSDC;
        escrowUSDCByToken[eventNFT][tokenId] = priceUSDC;
        originalMinter[eventNFT][tokenId] = msg.sender;

        emit TicketPurchasedUSDC(msg.sender, eventNFT, tokenId, tierIdx, priceUSDC, fee);
    }

    // -----------------------------------------------------------------
    // Compra con VBK — el neto queda en escrow (agregado + por token)
    // -----------------------------------------------------------------

    function buyWithVBK(address eventNFT, uint256 tierIdx, uint256 maxVbkAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        if (eventCancelled[eventNFT]) revert EventIsCancelled();

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

        // El fee se cobra ENCIMA del equivalente VBK del precio.
        // El comprador paga vbkNeeded + fee en total.
        if (fee > 0) vbk.safeTransferFrom(msg.sender, treasury, fee);
        vbk.safeTransferFrom(msg.sender, address(this), vbkNeeded);

        tokenId = evt.mintTicket(msg.sender, tierIdx, priceUSDC);

        escrowVBK[eventNFT] += vbkNeeded;
        escrowVBKByToken[eventNFT][tokenId] = vbkNeeded;
        originalMinter[eventNFT][tokenId] = msg.sender;

        emit TicketPurchasedVBK(msg.sender, eventNFT, tokenId, tierIdx, vbkNeeded, fee, priceUSDC);
    }

    // -----------------------------------------------------------------
    // Liberación del escrow — solo tras eventDate + gracia y sin cancelación
    // -----------------------------------------------------------------

    function releaseEscrow(address eventNFT) external nonReentrant {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        if (eventCancelled[eventNFT]) revert EventIsCancelled();
        if (escrowReleased[eventNFT]) revert AlreadyReleased();

        EventNFT evt = EventNFT(eventNFT);
        if (block.timestamp <= evt.eventDate() + RELEASE_GRACE) revert EventNotOver();

        uint256 usdcAmount = escrowUSDC[eventNFT];
        uint256 vbkAmount  = escrowVBK[eventNFT];
        if (usdcAmount == 0 && vbkAmount == 0) revert NothingToRelease();

        address organizer = evt.organizer();

        escrowReleased[eventNFT] = true;
        escrowUSDC[eventNFT] = 0;
        escrowVBK[eventNFT]  = 0;

        if (usdcAmount > 0) usdc.safeTransfer(organizer, usdcAmount);
        if (vbkAmount  > 0) vbk.safeTransfer(organizer, vbkAmount);

        emit EscrowReleased(eventNFT, organizer, usdcAmount, vbkAmount);
    }

    // -----------------------------------------------------------------
    // Reembolso voluntario (arrepentimiento) — comprador original, pre-cutoff
    // -----------------------------------------------------------------

    /**
     * @notice Reembolsa al comprador ORIGINAL que se arrepiente, quema la entrada
     *         y libera el cupo. Requiere firma del backend (refundSigner).
     * @dev    Digest firmado:
     *         keccak256(abi.encode(address(this), eventNFT, tokenId, msg.sender, deadline, chainid))
     *         con prefijo EIP-191 (toEthSignedMessageHash). El burn + el zero del
     *         escrow garantizan que no se pueda reembolsar dos veces (replay).
     */
    function refundVoluntary(
        address eventNFT,
        uint256 tokenId,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        if (eventCancelled[eventNFT]) revert EventIsCancelled();
        if (refundSigner == address(0)) revert RefundSignerNotSet();
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 digest = keccak256(
            abi.encode(address(this), eventNFT, tokenId, msg.sender, deadline, block.chainid)
        ).toEthSignedMessageHash();
        if (digest.recover(signature) != refundSigner) revert InvalidRefundSignature();

        EventNFT evt = EventNFT(eventNFT);
        if (evt.ownerOf(tokenId) != msg.sender) revert NotEventHolder();
        if (originalMinter[eventNFT][tokenId] != msg.sender) revert NotOriginalBuyer();
        if (evt.redeemed(tokenId)) revert TicketRedeemed();
        if (block.timestamp >= evt.eventDate() - REFUND_CUTOFF) revert RefundWindowClosed();

        uint256 u = escrowUSDCByToken[eventNFT][tokenId];
        uint256 v = escrowVBKByToken[eventNFT][tokenId];
        if (u == 0 && v == 0) revert NothingToRefund();

        // Effects
        escrowUSDCByToken[eventNFT][tokenId] = 0;
        escrowVBKByToken[eventNFT][tokenId]  = 0;
        escrowUSDC[eventNFT] -= u;
        escrowVBK[eventNFT]  -= v;

        uint256 uRestock = (u * restockFeeBps) / 10_000;
        uint256 vRestock = (v * restockFeeBps) / 10_000;
        uint256 uBuyer = u - uRestock;
        uint256 vBuyer = v - vRestock;

        // Interactions: quemar primero (saca el NFT), luego mover fondos.
        evt.refundBurn(tokenId);

        if (uBuyer   > 0) usdc.safeTransfer(msg.sender, uBuyer);
        if (uRestock > 0) usdc.safeTransfer(treasury, uRestock);
        if (vBuyer   > 0) vbk.safeTransfer(msg.sender, vBuyer);
        if (vRestock > 0) vbk.safeTransfer(treasury, vRestock);

        emit RefundedVoluntary(eventNFT, tokenId, msg.sender, uBuyer, vBuyer, uRestock, vRestock);
    }

    // -----------------------------------------------------------------
    // Reembolso por cancelación — al holder vigente (puede ser secundario)
    // -----------------------------------------------------------------

    /**
     * @notice Reembolsa el escrow de un token a su holder actual tras cancelar el
     *         evento. Cualquiera puede dispararlo; los fondos van a ownerOf(tokenId).
     *         No quema la entrada (el evento entero murió). Idempotente.
     */
    function refundCancelled(address eventNFT, uint256 tokenId) external nonReentrant {
        if (!factory.isEvent(eventNFT)) revert UnknownEvent();
        if (!eventCancelled[eventNFT]) revert EventNotCancelled();

        uint256 u = escrowUSDCByToken[eventNFT][tokenId];
        uint256 v = escrowVBKByToken[eventNFT][tokenId];
        if (u == 0 && v == 0) revert NothingToRefund();

        address holder = EventNFT(eventNFT).ownerOf(tokenId);

        // Effects
        escrowUSDCByToken[eventNFT][tokenId] = 0;
        escrowVBKByToken[eventNFT][tokenId]  = 0;
        escrowUSDC[eventNFT] -= u;
        escrowVBK[eventNFT]  -= v;

        uint256 uHolder = (u * cancelRefundBps) / 10_000;
        uint256 vHolder = (v * cancelRefundBps) / 10_000;

        if (uHolder > 0) usdc.safeTransfer(holder, uHolder);
        if (u - uHolder > 0) usdc.safeTransfer(treasury, u - uHolder);
        if (vHolder > 0) vbk.safeTransfer(holder, vHolder);
        if (v - vHolder > 0) vbk.safeTransfer(treasury, v - vHolder);

        emit RefundedCancelled(eventNFT, tokenId, holder, uHolder, vHolder);
    }

    // -----------------------------------------------------------------
    // Helpers de lectura (UX)
    // -----------------------------------------------------------------

    function quoteVBK(address eventNFT, uint256 tierIdx) external view returns (uint256) {
        EventNFT evt = EventNFT(eventNFT);
        (, uint256 priceUSDC, ,) = evt.tiers(tierIdx);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(vbk);
        uint256[] memory amounts = router.getAmountsOut(priceUSDC, path);
        return amounts[1];
    }

    function canRelease(address eventNFT) external view returns (bool) {
        if (!factory.isEvent(eventNFT)) return false;
        if (eventCancelled[eventNFT]) return false;
        if (escrowReleased[eventNFT]) return false;
        EventNFT evt = EventNFT(eventNFT);
        if (block.timestamp <= evt.eventDate() + RELEASE_GRACE) return false;
        return escrowUSDC[eventNFT] > 0 || escrowVBK[eventNFT] > 0;
    }

    /// @notice Hasta qué timestamp se puede pedir reembolso voluntario de este evento.
    function refundDeadline(address eventNFT) external view returns (uint256) {
        return EventNFT(eventNFT).eventDate() - REFUND_CUTOFF;
    }
}
