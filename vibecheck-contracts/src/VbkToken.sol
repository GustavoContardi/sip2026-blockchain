// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title VbkToken
 * @notice Moneda interna del ecosistema VibeCheck.
 *
 *         Tokenomics:
 *           - Supply FIJO: 100.000.000 VBK acuñados al deployer en el constructor.
 *           - NO existe `mint()`. El supply es inmutable a partir del deploy.
 *           - Burn-on-transfer del 2% (configurable hasta 10%) presiona deflación.
 *           - Direcciones exentas (pool AMM, OfferingNFT) no aplican burn para
 *             preservar invariantes del AMM y permitir el cobro nominal.
 *           - Pausable: el owner puede frenar transferencias en emergencias.
 *
 *         Pricing dinámico:
 *           - El precio surge de un pool de liquidez externo (Uniswap V2 VBK/USDC).
 *           - El pool address debe marcarse como `feeExempt` para que los swaps
 *             funcionen sin que la AMM cobre burn en cada operación interna.
 */
contract VbkToken is ERC20, ERC20Pausable, Ownable {
    /// @notice Supply total e inmutable: 100M VBK con 18 decimales.
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 1e18;

    /// @notice Tasa de burn en basis points (10000 = 100%). 200 = 2%.
    uint16 public burnRate;

    /// @notice Tope máximo configurable: 10%.
    uint16 public constant MAX_BURN_RATE = 1000;

    /// @notice Direcciones exentas del burn (pool AMM, OfferingNFT, Marketplace).
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

        // Owner exento por default: distribución inicial al pool, gateways, etc.
        isFeeExempt[owner_] = true;
        emit FeeExemptUpdated(owner_, true);

        // Acuñación única e inmutable: 100M al owner.
        _mint(owner_, INITIAL_SUPPLY);
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    /// @notice Ajusta el burn rate. Tope: MAX_BURN_RATE (10%).
    function setBurnRate(uint16 newRate) external onlyOwner {
        if (newRate > MAX_BURN_RATE) revert BurnRateTooHigh(newRate, MAX_BURN_RATE);
        emit BurnRateUpdated(burnRate, newRate);
        burnRate = newRate;
    }

    /// @notice Marca/desmarca una address como exenta del burn.
    ///         Casos típicos: pool Uniswap, OfferingNFT, NFTMarketplace.
    function setFeeExempt(address account, bool exempt) external onlyOwner {
        isFeeExempt[account] = exempt;
        emit FeeExemptUpdated(account, exempt);
    }

    /// @notice Pausa todas las transferencias. Solo owner.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Reanuda transferencias. Solo owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -----------------------------------------------------------------
    // Hook de transferencias: burn 2% + Pausable
    // -----------------------------------------------------------------

    /**
     * @dev Hook unificado de OZ v5: corre en mint, burn y transfer.
     *      - mint  (from == 0)              → no aplica burn.
     *      - burn  (to == 0)                → no aplica burn extra.
     *      - exenciones (from o to)         → no aplica burn.
     *      - resto                          → quema burnRate% del value.
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
