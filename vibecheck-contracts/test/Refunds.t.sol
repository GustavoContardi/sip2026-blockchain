// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {EventNFT} from "../src/EventNFT.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {OfferingNFT} from "../src/OfferingNFT.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";

contract MockERC20 {
    string public name; string public symbol; uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address sp, uint256 a) external returns (bool) { allowance[msg.sender][sp] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "insuf"); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "insuf"); require(allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract MockRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata) external pure returns (uint256[] memory a) {
        a = new uint256[](2); a[0] = amountIn; a[1] = amountIn * 10;
    }
}

contract RefundsTest is Test {
    address admin     = makeAddr("admin");
    address organizer = makeAddr("organizer");
    address treasury  = makeAddr("treasury");
    address buyer     = makeAddr("buyer");
    address reseller  = makeAddr("reseller");

    uint256 venueSignerPk  = 0x1337;
    uint256 refundSignerPk  = 0xBEEF;
    address venueSigner;
    address refundSigner;

    MockERC20 usdc; MockERC20 vbk; MockRouter router;
    EventFactory factory; OfferingNFT offering; NFTMarketplace marketplace; EventNFT nft;

    uint256 constant PRICE_USDC = 50 * 1e6;
    uint256 constant EVENT_DATE = 30 days;

    function setUp() public {
        venueSigner  = vm.addr(venueSignerPk);
        refundSigner = vm.addr(refundSignerPk);

        usdc = new MockERC20("USDC", "USDC", 6);
        vbk  = new MockERC20("VBK", "VBK", 18);
        router = new MockRouter();

        vm.startPrank(admin);
        factory = new EventFactory(admin, address(usdc), address(vbk), address(router), treasury);
        offering = new OfferingNFT(admin, factory, treasury);
        marketplace = new NFTMarketplace(admin, factory, treasury);
        factory.setOffering(address(offering));
        factory.setMarketplace(address(marketplace));
        offering.setRefundSigner(refundSigner);
        vm.stopPrank();

        EventFactory.EventParams memory p = EventFactory.EventParams({
            name: "Fest", symbol: "FEST", eventDate: block.timestamp + EVENT_DATE,
            maxResalePriceBps: 15_000, royaltyBps: 500, venueSigner: venueSigner, baseURI: "ipfs://t/"
        });
        EventNFT.Tier[] memory t = new EventNFT.Tier[](1);
        t[0] = EventNFT.Tier({name: "General", priceUSDC: PRICE_USDC, supply: 100, sold: 0});
        vm.prank(organizer);
        nft = EventNFT(factory.launchEvent(p, t));

        usdc.mint(buyer, 1_000 * 1e6);
        usdc.mint(reseller, 1_000 * 1e6);
        vbk.mint(buyer, 1_000_000 * 1e18);
    }

    // ---------- helpers ----------

    function _buyUSDC() internal returns (uint256 tokenId) {
        vm.startPrank(buyer);
        usdc.approve(address(offering), PRICE_USDC);
        tokenId = offering.buyWithUSDC(address(nft), 0);
        vm.stopPrank();
    }

    function _buyVBK() internal returns (uint256 tokenId) {
        vm.startPrank(buyer);
        uint256 q = offering.quoteVBK(address(nft), 0);
        vbk.approve(address(offering), q);
        tokenId = offering.buyWithVBK(address(nft), 0, q);
        vm.stopPrank();
    }

    function _signRefund(uint256 tokenId, address holder, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encode(address(offering), address(nft), tokenId, holder, deadline, block.chainid));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(digest);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(refundSignerPk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _resell(uint256 tokenId, uint256 price) internal {
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        uint256 lid = marketplace.list(address(nft), tokenId, price);
        vm.stopPrank();
        vm.startPrank(reseller);
        usdc.approve(address(marketplace), price);
        marketplace.buyWithUSDC(lid);
        vm.stopPrank();
    }

    // ══════════════════════════ Reembolso voluntario ══════════════════════════

    function test_refundVoluntary_USDC_success() public {
        uint256 tokenId = _buyUSDC();
        uint256 net = PRICE_USDC - (PRICE_USDC * 500) / 10_000; // 47.5e6
        uint256 restock = (net * 500) / 10_000;                 // 2.375e6
        uint256 toBuyer = net - restock;                        // 45.125e6

        uint256 balBefore = usdc.balanceOf(buyer);
        uint256 trBefore  = usdc.balanceOf(treasury);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRefund(tokenId, buyer, deadline);

        vm.prank(buyer);
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);

        assertEq(usdc.balanceOf(buyer) - balBefore, toBuyer, "buyer refund");
        assertEq(usdc.balanceOf(treasury) - trBefore, restock, "treasury restock");
        assertEq(offering.escrowUSDCByToken(address(nft), tokenId), 0, "token escrow zero");
        assertEq(offering.escrowUSDC(address(nft)), 0, "aggregate zero");
        (, , uint256 supply, uint256 sold) = nft.tiers(0);
        assertEq(supply, 100); assertEq(sold, 0, "slot freed");
        vm.expectRevert();
        nft.ownerOf(tokenId); // quemado
    }

    function test_refundVoluntary_VBK_success() public {
        uint256 tokenId = _buyVBK();
        uint256 q = PRICE_USDC * 10;                 // 500e6
        uint256 net = q - (q * 200) / 10_000;        // 490e6
        uint256 restock = (net * 500) / 10_000;
        uint256 toBuyer = net - restock;

        uint256 balBefore = vbk.balanceOf(buyer);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRefund(tokenId, buyer, deadline);

        vm.prank(buyer);
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);

        assertEq(vbk.balanceOf(buyer) - balBefore, toBuyer, "vbk refund");
        assertEq(offering.escrowVBKByToken(address(nft), tokenId), 0);
    }

    function test_refundVoluntary_reseller_reverts() public {
        uint256 tokenId = _buyUSDC();
        _resell(tokenId, 60 * 1e6); // ahora el holder es reseller

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRefund(tokenId, reseller, deadline);

        vm.prank(reseller);
        vm.expectRevert(OfferingNFT.NotOriginalBuyer.selector);
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);
    }

    function test_refundVoluntary_originalAfterResell_reverts() public {
        uint256 tokenId = _buyUSDC();
        _resell(tokenId, 60 * 1e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRefund(tokenId, buyer, deadline);

        vm.prank(buyer);
        vm.expectRevert(OfferingNFT.NotEventHolder.selector); // ya no es owner
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);
    }

    function test_refundVoluntary_afterCutoff_reverts() public {
        uint256 tokenId = _buyUSDC();
        vm.warp(nft.eventDate() - 71 hours); // dentro de las 72h
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRefund(tokenId, buyer, deadline);

        vm.prank(buyer);
        vm.expectRevert(OfferingNFT.RefundWindowClosed.selector);
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);
    }

    function test_refundVoluntary_badSignature_reverts() public {
        uint256 tokenId = _buyUSDC();
        uint256 deadline = block.timestamp + 1 hours;
        // firma con otra clave
        bytes32 digest = keccak256(abi.encode(address(offering), address(nft), tokenId, buyer, deadline, block.chainid));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, MessageHashUtils.toEthSignedMessageHash(digest));
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(buyer);
        vm.expectRevert(OfferingNFT.InvalidRefundSignature.selector);
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);
    }

    function test_refundVoluntary_expiredDeadline_reverts() public {
        uint256 tokenId = _buyUSDC();
        vm.warp(block.timestamp + 10);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signRefund(tokenId, buyer, deadline);

        vm.prank(buyer);
        vm.expectRevert(OfferingNFT.SignatureExpired.selector);
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);
    }

    function test_refundVoluntary_redeemed_reverts() public {
        uint256 tokenId = _buyUSDC();
        // redimir dentro de ventana [eventDate-1d, eventDate+1d]
        vm.warp(nft.eventDate() - 12 hours);
        bytes32 d = keccak256(abi.encode(address(nft), tokenId, block.chainid));
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(venueSignerPk, MessageHashUtils.toEthSignedMessageHash(d));
        vm.prank(buyer);
        nft.redeem(tokenId, abi.encodePacked(rr, ss, vv));

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRefund(tokenId, buyer, deadline);
        vm.prank(buyer);
        vm.expectRevert(OfferingNFT.TicketRedeemed.selector);
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);
    }

    function test_refundVoluntary_double_reverts() public {
        uint256 tokenId = _buyUSDC();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRefund(tokenId, buyer, deadline);
        vm.prank(buyer);
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);
        // segundo intento: token quemado → ownerOf revierte
        vm.prank(buyer);
        vm.expectRevert();
        offering.refundVoluntary(address(nft), tokenId, deadline, sig);
    }

    // ══════════════════════════ Cancelación ══════════════════════════

    function test_refundCancelled_paysCurrentHolder() public {
        uint256 tokenId = _buyUSDC();
        _resell(tokenId, 60 * 1e6); // holder = reseller
        uint256 net = PRICE_USDC - (PRICE_USDC * 500) / 10_000; // 47.5e6 en escrow

        vm.prank(admin);
        offering.cancelEvent(address(nft));

        uint256 before = usdc.balanceOf(reseller);
        offering.refundCancelled(address(nft), tokenId); // cualquiera lo dispara
        assertEq(usdc.balanceOf(reseller) - before, net, "holder cobra escrow completo");
        assertEq(offering.escrowUSDCByToken(address(nft), tokenId), 0);
    }

    function test_cancel_blocksRelease() public {
        _buyUSDC();
        vm.prank(admin);
        offering.cancelEvent(address(nft));
        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);
        vm.expectRevert(OfferingNFT.EventIsCancelled.selector);
        offering.releaseEscrow(address(nft));
    }

    function test_cancelAfterRelease_reverts() public {
        _buyUSDC();
        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);
        offering.releaseEscrow(address(nft));
        vm.prank(admin);
        vm.expectRevert(OfferingNFT.AlreadyReleased.selector);
        offering.cancelEvent(address(nft));
    }

    function test_buyWhenCancelled_reverts() public {
        vm.prank(admin);
        offering.cancelEvent(address(nft));
        vm.startPrank(buyer);
        usdc.approve(address(offering), PRICE_USDC);
        vm.expectRevert(OfferingNFT.EventIsCancelled.selector);
        offering.buyWithUSDC(address(nft), 0);
        vm.stopPrank();
    }

    function test_refundCancelled_notCancelled_reverts() public {
        uint256 tokenId = _buyUSDC();
        vm.expectRevert(OfferingNFT.EventNotCancelled.selector);
        offering.refundCancelled(address(nft), tokenId);
    }

    function test_refundCancelled_double_reverts() public {
        uint256 tokenId = _buyUSDC();
        vm.prank(admin);
        offering.cancelEvent(address(nft));
        offering.refundCancelled(address(nft), tokenId);
        vm.expectRevert(OfferingNFT.NothingToRefund.selector);
        offering.refundCancelled(address(nft), tokenId);
    }

    // ══════════════════════════ Gracia de release ══════════════════════════

    function test_release_beforeGrace_reverts() public {
        _buyUSDC();
        vm.warp(nft.eventDate() + 1); // pasó el evento pero no la gracia
        vm.expectRevert(OfferingNFT.EventNotOver.selector);
        offering.releaseEscrow(address(nft));
    }

    function test_release_afterGrace_success() public {
        _buyUSDC();
        uint256 net = PRICE_USDC - (PRICE_USDC * 500) / 10_000;
        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);
        uint256 before = usdc.balanceOf(organizer);
        offering.releaseEscrow(address(nft));
        assertEq(usdc.balanceOf(organizer) - before, net);
    }

    // ══════════════════════════ Marketplace bloqueado por cancelación ══════════════════

    function test_marketplace_listWhenCancelled_reverts() public {
        uint256 tokenId = _buyUSDC();
        vm.prank(admin);
        offering.cancelEvent(address(nft));

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        vm.expectRevert(NFTMarketplace.EventCancelled.selector);
        marketplace.list(address(nft), tokenId, 55 * 1e6);
        vm.stopPrank();
    }

    function test_marketplace_buyUSDCWhenCancelled_reverts() public {
        uint256 tokenId = _buyUSDC();
        // El listing se crea antes de la cancelación
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        uint256 lid = marketplace.list(address(nft), tokenId, 55 * 1e6);
        vm.stopPrank();

        vm.prank(admin);
        offering.cancelEvent(address(nft));

        // El listing existe y estaba activo, pero la compra queda bloqueada
        vm.startPrank(reseller);
        usdc.approve(address(marketplace), 55 * 1e6);
        vm.expectRevert(NFTMarketplace.EventCancelled.selector);
        marketplace.buyWithUSDC(lid);
        vm.stopPrank();
    }

    function test_marketplace_buyVBKWhenCancelled_reverts() public {
        uint256 tokenId = _buyUSDC();
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        uint256 lid = marketplace.list(address(nft), tokenId, 55 * 1e6);
        vm.stopPrank();

        vm.prank(admin);
        offering.cancelEvent(address(nft));

        uint256 q = 55 * 1e6 * 10; // ratio 1:10
        vbk.mint(reseller, q);
        vm.startPrank(reseller);
        vbk.approve(address(marketplace), q);
        vm.expectRevert(NFTMarketplace.EventCancelled.selector);
        marketplace.buyWithVBK(lid, q);
        vm.stopPrank();
    }

    function test_marketplace_cancelListingAfterEventCancel_succeeds() public {
        uint256 tokenId = _buyUSDC();
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        uint256 lid = marketplace.list(address(nft), tokenId, 55 * 1e6);
        vm.stopPrank();

        vm.prank(admin);
        offering.cancelEvent(address(nft));

        // El seller puede deslistarse aunque el evento esté cancelado
        vm.prank(buyer);
        marketplace.cancel(lid);
        assertFalse(marketplace.getListing(lid).active);
    }
}
