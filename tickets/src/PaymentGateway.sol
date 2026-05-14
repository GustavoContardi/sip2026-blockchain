// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PaymentGateway
 * @notice Recibe pagos en USDC y emite eventos para el backend.
 * @dev Cada proyecto extiende esto sobrescribiendo `_onPaid`.
 */
contract PaymentGateway is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public immutable treasury;

    event Paid(address indexed payer, uint256 amount, bytes32 indexed action);

    error AmountZero();
    error TreasuryZero();

    constructor(IERC20 _usdc, address _treasury) {
        if (_treasury == address(0)) revert TreasuryZero();
        usdc = _usdc;
        treasury = _treasury;
    }

    function pay(uint256 amount, bytes32 action) external nonReentrant {
        if (amount == 0) revert AmountZero();

        usdc.safeTransferFrom(msg.sender, treasury, amount);

        emit Paid(msg.sender, amount, action);

        _onPaid(msg.sender, amount, action);
    }

    function _onPaid(address payer, uint256 amount, bytes32 action) internal virtual {}
}
