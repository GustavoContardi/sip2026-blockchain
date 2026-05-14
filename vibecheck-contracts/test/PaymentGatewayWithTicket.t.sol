// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EventTicketNFT} from "../src/EventTicketNFT.sol";
import {PaymentGateway} from "../src/PaymentGateway.sol";
import {PaymentGatewayWithTicket} from "../src/PaymentGatewayWithTicket.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract PaymentGatewayWithTicketTest is Test {
    EventTicketNFT internal ticket;
    PaymentGatewayWithTicket internal gateway;
    MockUSDC internal usdc;
    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockUSDC();
        ticket = new EventTicketNFT("VibeCheck Entry", "VIBE-TKT", owner, "");
        gateway = new PaymentGatewayWithTicket(usdc, treasury, owner, ticket);
        ticket.setMinter(address(gateway));

        usdc.transfer(alice, 1000 * 10 ** 6);
        usdc.transfer(bob, 1000 * 10 ** 6);
    }

    // ------------------------------------------------------------
    // Flow base
    // ------------------------------------------------------------

    function test_PayMintsTicketToPayer() public {
        uint256 amount = 50 * 10 ** 6;
        vm.startPrank(alice);
        usdc.approve(address(gateway), amount);
        gateway.pay(amount, bytes32("vibecheck-2026"));
        vm.stopPrank();

        assertEq(ticket.balanceOf(alice), 1);
        assertEq(ticket.ownerOf(1), alice);
        assertEq(ticket.ticketAction(1), bytes32("vibecheck-2026"));
        assertEq(usdc.balanceOf(treasury), amount);
    }

    function test_MultiplePaymentsMintMultipleTickets() public {
        uint256 amount = 10 * 10 ** 6;

        vm.startPrank(alice);
        usdc.approve(address(gateway), amount * 3);
        gateway.pay(amount, bytes32("a1"));
        gateway.pay(amount, bytes32("a2"));
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(gateway), amount);
        gateway.pay(amount, bytes32("b1"));
        vm.stopPrank();

        assertEq(ticket.totalMinted(), 3);
        assertEq(ticket.balanceOf(alice), 2);
        assertEq(ticket.balanceOf(bob), 1);
        assertEq(ticket.ownerOf(3), bob);
    }

    function test_TicketsAreTransferable() public {
        uint256 amount = 50 * 10 ** 6;
        vm.startPrank(alice);
        usdc.approve(address(gateway), amount);
        gateway.pay(amount, bytes32("transfer-test"));
        ticket.transferFrom(alice, bob, 1);
        vm.stopPrank();

        assertEq(ticket.ownerOf(1), bob);
    }

    function test_OnlyMinterCanMint() public {
        vm.expectRevert(EventTicketNFT.NotMinter.selector);
        ticket.mintTicket(alice, bytes32("hack"));
    }

    function test_OwnerCanUpdateBaseURI() public {
        ticket.setBaseURI("ipfs://nuevo-cid/");
        uint256 amount = 10 * 10 ** 6;
        vm.startPrank(alice);
        usdc.approve(address(gateway), amount);
        gateway.pay(amount, bytes32("uri-test"));
        vm.stopPrank();
        assertEq(ticket.tokenURI(1), "ipfs://nuevo-cid/1");
    }

    function test_SetMinter_RevertsOnZeroAddress() public {
        vm.expectRevert(EventTicketNFT.ZeroAddress.selector);
        ticket.setMinter(address(0));
    }

    // ------------------------------------------------------------
    // Pausable: gateway
    // ------------------------------------------------------------

    function test_Pause_BlocksPayments() public {
        gateway.pause();

        vm.startPrank(alice);
        usdc.approve(address(gateway), 50 * 10 ** 6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.pay(50 * 10 ** 6, bytes32("blocked"));
        vm.stopPrank();
    }

    function test_Unpause_ResumesPayments() public {
        gateway.pause();
        gateway.unpause();

        vm.startPrank(alice);
        usdc.approve(address(gateway), 50 * 10 ** 6);
        gateway.pay(50 * 10 ** 6, bytes32("resumed"));
        vm.stopPrank();

        assertEq(ticket.balanceOf(alice), 1);
    }

    function test_OnlyOwner_CanPauseGateway() public {
        vm.prank(alice);
        vm.expectRevert();
        gateway.pause();
    }

    // ------------------------------------------------------------
    // Pausable: NFT
    // ------------------------------------------------------------

    function test_PauseNFT_BlocksTransfers() public {
        // Comprar un ticket primero
        vm.startPrank(alice);
        usdc.approve(address(gateway), 50 * 10 ** 6);
        gateway.pay(50 * 10 ** 6, bytes32("pre-pause"));
        vm.stopPrank();

        // Pausar el NFT
        ticket.pause();

        // Transferencia debe fallar
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ticket.transferFrom(alice, bob, 1);
    }

    function test_PauseNFT_BlocksMinting() public {
        ticket.pause();

        vm.startPrank(alice);
        usdc.approve(address(gateway), 50 * 10 ** 6);
        // El pay() del gateway revierte porque el mint del NFT revierte.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.pay(50 * 10 ** 6, bytes32("blocked-mint"));
        vm.stopPrank();
    }

    // ------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------

    function testFuzz_PaymentMintsExactlyOneTicket(uint96 amount, bytes32 action) public {
        amount = uint96(bound(uint256(amount), 1, 100 * 10 ** 6));
        vm.startPrank(alice);
        usdc.approve(address(gateway), amount);
        gateway.pay(amount, action);
        vm.stopPrank();

        assertEq(ticket.balanceOf(alice), 1);
        assertEq(ticket.totalMinted(), 1);
    }

    // ------------------------------------------------------------
    // Cobertura de constructors y views
    // ------------------------------------------------------------

    function test_Constructor_RevertsOnTreasuryZero() public {
        vm.expectRevert(PaymentGateway.TreasuryZero.selector);
        new PaymentGatewayWithTicket(usdc, address(0), owner, ticket);
    }

    function test_TotalMinted_TracksCount() public {
        assertEq(ticket.totalMinted(), 0);

        vm.startPrank(alice);
        usdc.approve(address(gateway), 50 * 10 ** 6);
        gateway.pay(50 * 10 ** 6, bytes32("count-1"));
        vm.stopPrank();

        assertEq(ticket.totalMinted(), 1);
    }

    function test_NFT_Unpause_ResumesMinting() public {
        ticket.pause();
        ticket.unpause();

        vm.startPrank(alice);
        usdc.approve(address(gateway), 50 * 10 ** 6);
        gateway.pay(50 * 10 ** 6, bytes32("resumed-nft"));
        vm.stopPrank();

        assertEq(ticket.balanceOf(alice), 1);
    }

    function test_Pay_RevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(PaymentGateway.AmountZero.selector);
        gateway.pay(0, bytes32("zero"));
    }

    function test_Gateway_Unpause_AfterPause() public {
        gateway.pause();
        gateway.unpause();
        // Confirmar que después de unpause se puede pagar
        vm.startPrank(alice);
        usdc.approve(address(gateway), 1000000);
        gateway.pay(1000000, bytes32("after-unpause"));
        vm.stopPrank();
        assertEq(ticket.balanceOf(alice), 1);
    }
}
