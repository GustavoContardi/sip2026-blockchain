// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PaymentGateway} from "../src/PaymentGateway.sol";

contract MockUSDCReentrancy is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// Subclase atacante: en _onPaid intenta llamar pay() de nuevo.
contract ReentrantGateway is PaymentGateway {
    bool public attacked;

    constructor(ERC20 _usdc, address _treasury, address _owner)
        PaymentGateway(_usdc, _treasury, _owner)
    {}

    function _onPaid(address payer, uint256 amount, bytes32 action) internal override {
        if (!attacked) {
            attacked = true;
            this.pay(amount, action); // debe revertir por nonReentrant
        }
    }
}

contract ReentrancyAttackTest is Test {
    ReentrantGateway internal gateway;
    MockUSDCReentrancy internal usdc;
    address internal alice = makeAddr("alice");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockUSDCReentrancy();
        gateway = new ReentrantGateway(usdc, treasury, address(this));
        usdc.transfer(alice, 1000 * 10 ** 6);
    }

    function test_ReentrancyIsBlocked() public {
        uint256 amount = 50 * 10 ** 6;

        vm.startPrank(alice);
        usdc.approve(address(gateway), amount * 2);

        vm.expectRevert(
            abi.encodeWithSignature("ReentrancyGuardReentrantCall()")
        );
        gateway.pay(amount, bytes32("attack"));
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(alice), 1000 * 10 ** 6);
    }
}
