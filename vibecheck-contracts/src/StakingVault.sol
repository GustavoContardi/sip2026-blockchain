// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title StakingVault
 * @notice Bloqueo temporal (lock) de $VBK por términos fijos (por defecto 30/60/90 días).
 *
 *  MODELO (decisión de diseño):
 *   - NO paga rendimiento en VBK. La "recompensa" es de utilidad (tier de fan,
 *     acceso a preventas, multiplicador de cashback) y se calcula OFF-CHAIN a
 *     partir del estado del lock que este contrato expone por vistas y eventos.
 *   - Como no hay payout on-chain, no existe pool de rewards ni riesgo de
 *     insolvencia. `withdraw` devuelve exactamente el principal custodiado.
 *
 *  CUSTODIA:
 *   - El VBK queda retenido en este contrato durante el término. Eso es lo que
 *     impide venderlo mientras dure el lock (el usuario no lo tiene; lo tiene el vault).
 *
 *  COMPATIBILIDAD CON EL BURN DE VbkToken:
 *   - Este contrato DEBE estar marcado como feeExempt en VbkToken. Si no lo está,
 *     el usuario pierde el burn (2%) al depositar y otro 2% al retirar.
 *   - Defensa adicional: se acredita el monto REALMENTE recibido (delta de balance),
 *     de modo que aunque por error el vault no esté exento, la contabilidad sigue
 *     siendo correcta y el contrato nunca promete devolver más VBK del que tiene.
 *
 *  No se permite retiro anticipado: locked es locked.
 */
contract StakingVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable vbk;

    struct Lock {
        uint256 amount;     // VBK realmente custodiado para este lock
        uint64  start;      // timestamp de creación
        uint64  unlockTime; // timestamp a partir del cual se puede retirar
        uint32  termDays;   // término elegido (p. ej. 30/60/90)
        bool    withdrawn;  // si ya fue retirado
    }

    // Locks por usuario. Append-only: el lockId es el índice y se mantiene estable.
    mapping(address => Lock[]) private _locks;

    // Términos permitidos, en días. Sembrados con 30/60/90 en el constructor.
    mapping(uint32 => bool) public allowedTermDays;

    // Suma del VBK custodiado (no retirado) por usuario. Conveniencia para el backend.
    mapping(address => uint256) public totalLocked;

    // ------------------------------------------------------------------ events
    event TermSet(uint32 indexed termDays, bool allowed);
    event Locked(
        address indexed user,
        uint256 indexed lockId,
        uint256 amount,
        uint32  termDays,
        uint64  unlockTime
    );
    event Withdrawn(address indexed user, uint256 indexed lockId, uint256 amount);

    // ------------------------------------------------------------------ errors
    error TermNotAllowed(uint32 termDays);
    error ZeroAmount();
    error NothingReceived();
    error InvalidLockId();
    error AlreadyWithdrawn();
    error StillLocked(uint64 unlockTime);

    constructor(address vbkToken, address initialOwner) Ownable(initialOwner) {
        require(vbkToken != address(0), "vbk=0");
        vbk = IERC20(vbkToken);
        _setTerm(30, true);
        _setTerm(60, true);
        _setTerm(90, true);
    }

    // ------------------------------------------------------------ admin (owner)

    /// @notice Habilita o deshabilita un término (en días). No afecta locks ya creados.
    function setTerm(uint32 termDays, bool allowed) external onlyOwner {
        _setTerm(termDays, allowed);
    }

    function _setTerm(uint32 termDays, bool allowed) internal {
        require(termDays > 0, "term=0");
        allowedTermDays[termDays] = allowed;
        emit TermSet(termDays, allowed);
    }

    /// @notice Pausa SOLO nuevos stakes. Los retiros nunca se bloquean.
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ---------------------------------------------------------------- actions

    /**
     * @notice Bloquea `amount` de VBK por `termDays`.
     * @dev Acredita el monto realmente recibido (delta de balance) para ser robusto
     *      frente al burn del token. Requiere approve previo del usuario al vault.
     * @return lockId índice del lock creado para msg.sender.
     */
    function stake(uint256 amount, uint32 termDays)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 lockId)
    {
        if (amount == 0) revert ZeroAmount();
        if (!allowedTermDays[termDays]) revert TermNotAllowed(termDays);

        uint256 balBefore = vbk.balanceOf(address(this));
        vbk.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = vbk.balanceOf(address(this)) - balBefore;
        if (received == 0) revert NothingReceived();

        uint64 unlockTime = uint64(block.timestamp + uint256(termDays) * 1 days);

        lockId = _locks[msg.sender].length;
        _locks[msg.sender].push(
            Lock({
                amount: received,
                start: uint64(block.timestamp),
                unlockTime: unlockTime,
                termDays: termDays,
                withdrawn: false
            })
        );
        totalLocked[msg.sender] += received;

        emit Locked(msg.sender, lockId, received, termDays, unlockTime);
    }

    /**
     * @notice Retira un lock ya vencido. No hay retiro anticipado.
     */
    function withdraw(uint256 lockId) external nonReentrant {
        Lock[] storage userLocks = _locks[msg.sender];
        if (lockId >= userLocks.length) revert InvalidLockId();

        Lock storage lock = userLocks[lockId];
        if (lock.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < lock.unlockTime) revert StillLocked(lock.unlockTime);

        uint256 amount = lock.amount;

        // CEI: efectos antes de la interacción externa.
        lock.withdrawn = true;
        totalLocked[msg.sender] -= amount;

        vbk.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, lockId, amount);
    }

    // ----------------------------------------------------- views (backend/UI)

    function getLockCount(address user) external view returns (uint256) {
        return _locks[user].length;
    }

    function getLock(address user, uint256 lockId) external view returns (Lock memory) {
        require(lockId < _locks[user].length, "bad id");
        return _locks[user][lockId];
    }

    function getLocks(address user) external view returns (Lock[] memory) {
        return _locks[user];
    }

    function isWithdrawable(address user, uint256 lockId) external view returns (bool) {
        if (lockId >= _locks[user].length) return false;
        Lock storage lock = _locks[user][lockId];
        return !lock.withdrawn && block.timestamp >= lock.unlockTime;
    }

    /**
     * @notice VBK custodiado (no retirado) de un usuario cuyo término sea >= `minTermDays`.
     *         Pensado para que el backend calcule tiers (p. ej. "tiene >= X bloqueado a >= 90 días").
     *         Un lock vencido pero no retirado sigue contando: mientras el VBK esté en el
     *         vault, otorga beneficio. El usuario lo corta retirando.
     */
    function activeLockedByMinTerm(address user, uint32 minTermDays)
        external
        view
        returns (uint256 total)
    {
        Lock[] storage userLocks = _locks[user];
        uint256 len = userLocks.length;
        for (uint256 i = 0; i < len; i++) {
            Lock storage lock = userLocks[i];
            if (!lock.withdrawn && lock.termDays >= minTermDays) {
                total += lock.amount;
            }
        }
    }
}
