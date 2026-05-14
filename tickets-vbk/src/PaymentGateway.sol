// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {PaymentGateway} from "../src/PaymentGateway.sol";

/**
 * @title PaymentGateway
 * @notice Recibe pagos en USDC y emite eventos para el backend.
 * @dev Cada proyecto extiende esto sobrescribiendo `_onPaid`.
 *      Seguridad:
 *        - ReentrancyGuard: protege contra ataques de reentrancy.
 *        - Ownable: permite designar un admin (controla pause).
 *        - Pausable: el owner puede frenar `pay()` en emergencias.
 */
contract PaymentGateway is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public immutable treasury;

    event Paid(address indexed payer, uint256 amount, bytes32 indexed action);

    error AmountZero();
    error TreasuryZero();

    constructor(IERC20 _usdc, address _treasury, address _owner) Ownable(_owner) {
        if (_treasury == address(0)) revert TreasuryZero();
        usdc = _usdc;
        treasury = _treasury;
    }

    /// @notice Procesar un pago en USDC. Revierte si el contrato está pausado.
    function pay(uint256 amount, bytes32 action) external nonReentrant whenNotPaused {
        if (amount == 0) revert AmountZero();

        usdc.safeTransferFrom(msg.sender, treasury, amount);

        emit Paid(msg.sender, amount, action);

        _onPaid(msg.sender, amount, action);
    }

    /// @notice Pausa el gateway. Solo owner. Detiene todos los `pay()`.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Reanuda el gateway. Solo owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    function _onPaid(address payer, uint256 amount, bytes32 action) internal virtual {}
}
