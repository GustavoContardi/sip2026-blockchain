// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EventTicketNFT} from "../src/EventTicketNFT.sol";
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
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockUSDC();
        // Deployer (este test) queda como owner del ticket (gestiona metadata).
        ticket = new EventTicketNFT("VibeCheck Entry", "VIBE-TKT", address(this), "");
        gateway = new PaymentGatewayWithTicket(usdc, treasury, ticket);
        // Designar al gateway como minter.
        ticket.setMinter(address(gateway));

        usdc.transfer(alice, 1000 * 10 ** 6);
        usdc.transfer(bob, 1000 * 10 ** 6);
    }

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
        // El deployer (address(this)) es owner pero NO minter.
        vm.expectRevert(EventTicketNFT.NotMinter.selector);
        ticket.mintTicket(alice, bytes32("hack"));
    }

    function test_OwnerCanUpdateBaseURI() public {
        // Owner sigue siendo el deployer aunque el minter sea el gateway.
        ticket.setBaseURI("ipfs://nuevo-cid/");
        // Sin un tokenId no se puede verificar tokenURI sin antes mintear,
        // así que minteamos uno vía gateway y leemos.
        uint256 amount = 10 * 10 ** 6;
        vm.startPrank(alice);
        usdc.approve(address(gateway), amount);
        gateway.pay(amount, bytes32("uri-test"));
        vm.stopPrank();
        assertEq(ticket.tokenURI(1), "ipfs://nuevo-cid/1");
    }

    function testFuzz_PaymentMintsExactlyOneTicket(uint96 amount, bytes32 action) public {
        amount = uint96(bound(uint256(amount), 1, 100 * 10 ** 6));
        vm.startPrank(alice);
        usdc.approve(address(gateway), amount);
        gateway.pay(amount, action);
        vm.stopPrank();

        assertEq(ticket.balanceOf(alice), 1);
        assertEq(ticket.totalMinted(), 1);
    }
}
