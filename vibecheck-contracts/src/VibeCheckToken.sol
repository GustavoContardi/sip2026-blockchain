// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibeCheckToken
 * @notice Moneda interna del ecosistema VibeCheck.
 *         - ERC-20 estándar con 18 decimales.
 *         - Supply inicial: 10.000 VBK al deployer.
 *         - Pricing dinámico: el precio surge de un pool de liquidez externo
 *           (Uniswap). Para que el AMM funcione correctamente, el pool address
 *           se exenta del burn via `setFeeExempt`.
 *         - Burn-on-transfer: 2% de cada transferencia usuario→usuario se quema,
 *           presionando deflación. Mints, burns directos y direcciones exentas
 *           no aplican.
 *         - Solo el owner mintea (`mint`).
 *         - Pausable: el owner puede frenar transferencias en emergencias.
 *         - ReentrancyGuard heredado para futuras extensiones (redeem, claim, etc.).
 */
contract VibeCheckToken is ERC20, ERC20Pausable, Ownable, ReentrancyGuard {
    /// @notice Supply inicial acuñado al deployer (10.000 VBK con 18 decimales).
    uint256 public constant INITIAL_SUPPLY = 10_000 * 1e18;

    /// @notice Tasa de burn en basis points (10000 = 100%). 200 = 2%.
    uint16 public burnRate;

    /// @notice Tope máximo configurable.
    uint16 public constant MAX_BURN_RATE = 1000; // 10%

    /// @notice Direcciones que no pagan burn al enviar/recibir (pool AMM, gateway, etc.).
    mapping(address => bool) public isFeeExempt;

    event BurnRateUpdated(uint16 previousRate, uint16 newRate);
    event FeeExemptUpdated(address indexed account, bool exempt);
    event Burned(address indexed from, uint256 amount);

    error BurnRateTooHigh(uint16 rate, uint16 max);

    constructor(address owner_)
        ERC20("VibeCheckToken", "VBK")
        Ownable(owner_)
    {
        burnRate = 200; // 2% default
        // Owner exento por default: distribución inicial y operaciones administrativas.
        isFeeExempt[owner_] = true;
        emit FeeExemptUpdated(owner_, true);

        // Supply inicial: 10.000 VBK al deployer/owner.
        _mint(owner_, INITIAL_SUPPLY);
    }

    // ----------------------------------------------------------------
    // Admin
    // ----------------------------------------------------------------

    /// @notice Ajustar el burn rate. Tope: MAX_BURN_RATE (10%).
    function setBurnRate(uint16 newRate) external onlyOwner {
        if (newRate > MAX_BURN_RATE) revert BurnRateTooHigh(newRate, MAX_BURN_RATE);
        emit BurnRateUpdated(burnRate, newRate);
        burnRate = newRate;
    }

    /// @notice Marcar una address como exenta (o no exenta) del burn.
    ///         Casos típicos: pool de Uniswap, PaymentGateway, contratos de staking.
    function setFeeExempt(address account, bool exempt) external onlyOwner {
        isFeeExempt[account] = exempt;
        emit FeeExemptUpdated(account, exempt);
    }

    /// @notice Emitir tokens nuevos. Solo el owner.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Pausa todas las transferencias y mints. Solo owner.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Reanuda transferencias. Solo owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ----------------------------------------------------------------
    // Lógica de burn-on-transfer + Pausable
    // ----------------------------------------------------------------

    /**
     * @dev Hook unificado de OZ v5: corre en mint, burn y transfer.
     *      - Si from == 0 → es un mint, no aplicamos burn.
     *      - Si to == 0 → es un burn directo, no aplicamos burn extra.
     *      - Si from o to están exentos (pool AMM, gateway) → no aplicamos burn.
     *      - En el resto, descontamos burnRate% del `value` y lo quemamos.
     *      ERC20Pausable agrega `whenNotPaused`.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        bool isMintOrBurn = (from == address(0) || to == address(0));
        bool exempt = isFeeExempt[from] || isFeeExempt[to];

        if (!isMintOrBurn && !exempt && burnRate > 0 && value > 0) {
            uint256 burnAmount = (value * burnRate) / 10000;
            if (burnAmount > 0) {
                super._update(from, address(0), burnAmount);
                emit Burned(from, burnAmount);
                value -= burnAmount;
            }
        }

        super._update(from, to, value);
    }
}
