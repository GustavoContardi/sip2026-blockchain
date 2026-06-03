// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {EventNFT} from "../src/EventNFT.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {OfferingNFT} from "../src/OfferingNFT.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";

// Mock minimalista de USDC/VBK (ERC-20)
contract MockERC20 {
    string public name;
    string public symbol;
    uint8  public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8 d) {
        name = n; symbol = s; decimals = d;
    }

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt; emit Approval(msg.sender, sp, amt); return true;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insuf");
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt); return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "insuf");
        require(allowance[from][msg.sender] >= amt, "allowance");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt; balanceOf[to] += amt;
        emit Transfer(from, to, amt); return true;
    }
    function totalSupply() external view returns (uint256) { return 0; }
}

// Mock del router de Uniswap V2 (solo getAmountsOut)
contract MockUniswapRouter {
    uint256 public constant RATIO = 10; // 1 USDC = 10 VBK

    function getAmountsOut(uint256 amountIn, address[] calldata)
        external pure returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * RATIO;
    }
}

contract OfferingAndMarketplaceTest is Test, ERC721Holder {
    address admin     = makeAddr("admin");
    address organizer = makeAddr("organizer");
    address treasury  = makeAddr("treasury");
    address buyer     = makeAddr("buyer");
    address seller    = makeAddr("seller");
    address reseller  = makeAddr("reseller");

    uint256 venueSignerPk = 0x1337;
    address venueSigner   = vm.addr(venueSignerPk);

    MockERC20         public usdc;
    MockERC20         public vbk;
    MockUniswapRouter public router;
    EventFactory      public factory;
    OfferingNFT       public offering;
    NFTMarketplace    public marketplace;
    EventNFT          public nft;

    uint256 constant PRICE_USDC = 50 * 1e6;
    uint256 constant EVENT_DATE = 30 days;

    function setUp() public {
        usdc   = new MockERC20("USDC", "USDC", 6);
        vbk    = new MockERC20("VBK", "VBK", 18);
        router = new MockUniswapRouter();

        vm.prank(admin);
        factory = new EventFactory(admin, address(usdc), address(vbk), address(router), treasury);
        vm.prank(admin);
        offering = new OfferingNFT(admin, factory, treasury);
        vm.prank(admin);
        marketplace = new NFTMarketplace(admin, factory, treasury);

        vm.startPrank(admin);
        factory.setOffering(address(offering));
        factory.setMarketplace(address(marketplace));
        vm.stopPrank();

        EventFactory.EventParams memory p = EventFactory.EventParams({
            name: "Festival Test",
            symbol: "FEST",
            eventDate: block.timestamp + EVENT_DATE,
            maxResalePriceBps: 15_000,
            royaltyBps: 500,
            venueSigner: venueSigner,
            baseURI: "ipfs://test/"
        });
        EventNFT.Tier[] memory t = new EventNFT.Tier[](1);
        t[0] = EventNFT.Tier({name: "General", priceUSDC: PRICE_USDC, supply: 100, sold: 0});

        // Cualquier wallet puede lanzar — sin grantOrganizer
        vm.prank(organizer);
        nft = EventNFT(factory.launchEvent(p, t));

        usdc.mint(buyer,    1_000 * 1e6);
        usdc.mint(seller,   1_000 * 1e6);
        usdc.mint(reseller, 1_000 * 1e6);
        vbk.mint(buyer,     1_000_000 * 1e18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // OfferingNFT — buyWithUSDC
    // ══════════════════════════════════════════════════════════════════════════

    function test_buyWithUSDC_success() public {
        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);

        vm.prank(buyer);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), buyer);

        uint256 fee = PRICE_USDC * 500 / 10_000;
        // El fee va directo al treasury
        assertEq(usdc.balanceOf(treasury), fee);
        // El organizador NO cobra al instante: el neto queda en escrow
        assertEq(usdc.balanceOf(organizer), 0);
        assertEq(offering.escrowUSDC(address(nft)), PRICE_USDC - fee);
        // Los fondos del neto están físicamente en el contrato
        assertEq(usdc.balanceOf(address(offering)), PRICE_USDC - fee);
    }

    function test_buyWithUSDC_unknownEvent_reverts() public {
        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);

        vm.prank(buyer);
        vm.expectRevert(OfferingNFT.UnknownEvent.selector);
        offering.buyWithUSDC(address(0xBAD), 0);
    }

    function test_buyWithUSDC_invalidTier_reverts() public {
        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);

        vm.prank(buyer);
        vm.expectRevert(OfferingNFT.TierOutOfRange.selector);
        offering.buyWithUSDC(address(nft), 99);
    }

    function test_buyWithUSDC_paused_reverts() public {
        vm.prank(admin);
        offering.pause();

        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);

        vm.prank(buyer);
        vm.expectRevert();
        offering.buyWithUSDC(address(nft), 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // OfferingNFT — buyWithVBK
    // ══════════════════════════════════════════════════════════════════════════

    function test_buyWithVBK_success() public {
        uint256 vbkNeeded = PRICE_USDC * 10;
        uint256 maxVbk    = vbkNeeded * 110 / 100;

        vm.prank(buyer);
        vbk.approve(address(offering), maxVbk);

        vm.prank(buyer);
        uint256 tokenId = offering.buyWithVBK(address(nft), 0, maxVbk);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), buyer);

        uint256 fee = vbkNeeded * 200 / 10_000;
        // El fee va directo al treasury
        assertEq(vbk.balanceOf(treasury), fee);
        // El organizador NO cobra al instante: el neto queda en escrow
        assertEq(vbk.balanceOf(organizer), 0);
        assertEq(offering.escrowVBK(address(nft)), vbkNeeded - fee);
        assertEq(nft.originalPrice(1), PRICE_USDC);
    }

    function test_buyWithVBK_slippageTooHigh_reverts() public {
        uint256 vbkNeeded = PRICE_USDC * 10;
        uint256 maxVbk    = vbkNeeded - 1;

        vm.prank(buyer);
        vbk.approve(address(offering), vbkNeeded);

        vm.prank(buyer);
        vm.expectRevert();
        offering.buyWithVBK(address(nft), 0, maxVbk);
    }

    function test_buyWithVBK_feeDiscount() public view {
        assertLt(offering.platformFeeBpsVBK(), offering.platformFeeBpsUSDC());
    }

    function test_quoteVBK() public view {
        uint256 quote = offering.quoteVBK(address(nft), 0);
        assertEq(quote, PRICE_USDC * 10);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // OfferingNFT — Escrow / releaseEscrow
    // ══════════════════════════════════════════════════════════════════════════

    function test_releaseEscrow_USDC_afterEvent() public {
        // Compra con USDC → el neto queda en escrow
        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(buyer);
        offering.buyWithUSDC(address(nft), 0);

        uint256 fee     = PRICE_USDC * 500 / 10_000;
        uint256 netToOrg = PRICE_USDC - fee;
        assertEq(offering.escrowUSDC(address(nft)), netToOrg);

        // Antes de la fecha del evento NO se puede liberar
        assertFalse(offering.canRelease(address(nft)));

        // Avanzar más allá de la fecha del evento
        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);
        assertTrue(offering.canRelease(address(nft)));

        // Liberar el escrow → el organizador cobra
        offering.releaseEscrow(address(nft));

        assertEq(usdc.balanceOf(organizer), netToOrg);
        assertEq(offering.escrowUSDC(address(nft)), 0);
        assertTrue(offering.escrowReleased(address(nft)));
    }

    function test_releaseEscrow_VBK_afterEvent() public {
        uint256 vbkNeeded = PRICE_USDC * 10;
        uint256 maxVbk    = vbkNeeded * 110 / 100;

        vm.prank(buyer);
        vbk.approve(address(offering), maxVbk);
        vm.prank(buyer);
        offering.buyWithVBK(address(nft), 0, maxVbk);

        uint256 fee      = vbkNeeded * 200 / 10_000;
        uint256 netToOrg = vbkNeeded - fee;
        assertEq(offering.escrowVBK(address(nft)), netToOrg);

        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);
        offering.releaseEscrow(address(nft));

        assertEq(vbk.balanceOf(organizer), netToOrg);
        assertEq(offering.escrowVBK(address(nft)), 0);
    }

    function test_releaseEscrow_mixedUSDCandVBK() public {
        // Una compra en USDC y otra en VBK sobre el mismo evento
        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(buyer);
        offering.buyWithUSDC(address(nft), 0);

        uint256 vbkNeeded = PRICE_USDC * 10;
        uint256 maxVbk    = vbkNeeded * 110 / 100;
        vm.prank(buyer);
        vbk.approve(address(offering), maxVbk);
        vm.prank(buyer);
        offering.buyWithVBK(address(nft), 0, maxVbk);

        uint256 usdcNet = PRICE_USDC - (PRICE_USDC * 500 / 10_000);
        uint256 vbkNet  = vbkNeeded - (vbkNeeded * 200 / 10_000);

        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);
        offering.releaseEscrow(address(nft));

        assertEq(usdc.balanceOf(organizer), usdcNet);
        assertEq(vbk.balanceOf(organizer), vbkNet);
    }

    function test_releaseEscrow_beforeEvent_reverts() public {
        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(buyer);
        offering.buyWithUSDC(address(nft), 0);

        // Todavía no pasó la fecha del evento
        vm.expectRevert(OfferingNFT.EventNotOver.selector);
        offering.releaseEscrow(address(nft));
    }

    function test_releaseEscrow_twice_reverts() public {
        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(buyer);
        offering.buyWithUSDC(address(nft), 0);

        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);
        offering.releaseEscrow(address(nft));

        // Segundo intento → revierte
        vm.expectRevert(OfferingNFT.AlreadyReleased.selector);
        offering.releaseEscrow(address(nft));
    }

    function test_releaseEscrow_nothingToRelease_reverts() public {
        // Evento sin ventas
        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);
        vm.expectRevert(OfferingNFT.NothingToRelease.selector);
        offering.releaseEscrow(address(nft));
    }

    function test_releaseEscrow_unknownEvent_reverts() public {
        vm.warp(block.timestamp + EVENT_DATE + 1);
        vm.expectRevert(OfferingNFT.UnknownEvent.selector);
        offering.releaseEscrow(address(0xBAD));
    }

    function test_releaseEscrow_anyoneCanTrigger_fundsGoToOrganizer() public {
        // Cualquiera puede disparar la liberación, pero el dinero va al organizador
        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(buyer);
        offering.buyWithUSDC(address(nft), 0);

        uint256 netToOrg = PRICE_USDC - (PRICE_USDC * 500 / 10_000);

        vm.warp(nft.eventDate() + offering.RELEASE_GRACE() + 1);

        // Lo dispara un tercero (reseller), no el organizador
        vm.prank(reseller);
        offering.releaseEscrow(address(nft));

        // El dinero igual fue al organizador
        assertEq(usdc.balanceOf(organizer), netToOrg);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // NFTMarketplace — list / cancel / buy
    // ══════════════════════════════════════════════════════════════════════════

    function _buyTicketForSeller() internal returns (uint256 tokenId) {
        vm.prank(seller);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(seller);
        tokenId = offering.buyWithUSDC(address(nft), 0);
    }

    function test_list_success() public {
        uint256 tokenId   = _buyTicketForSeller();
        uint256 listPrice = 60 * 1e6;

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, listPrice);

        (address s, address e, uint256 t, uint256 p, bool active) = _getListing(listingId);
        assertEq(s, seller);
        assertEq(e, address(nft));
        assertEq(t, tokenId);
        assertEq(p, listPrice);
        assertTrue(active);
    }

    function test_list_priceAboveCap_reverts() public {
        uint256 tokenId = _buyTicketForSeller();
        uint256 overCap = 80 * 1e6;

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);

        vm.prank(seller);
        vm.expectRevert();
        marketplace.list(address(nft), tokenId, overCap);
    }

    function test_list_revertAfterEventDate() public {
        uint256 tokenId = _buyTicketForSeller();
        vm.warp(block.timestamp + EVENT_DATE + 1);

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);

        vm.prank(seller);
        vm.expectRevert(NFTMarketplace.EventOver.selector);
        marketplace.list(address(nft), tokenId, 60 * 1e6);
    }

    function test_cancel_success() public {
        uint256 tokenId = _buyTicketForSeller();
        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, 60 * 1e6);

        vm.prank(seller);
        marketplace.cancel(listingId);

        (, , , , bool active) = _getListing(listingId);
        assertFalse(active);
    }

    function test_cancel_notSeller_reverts() public {
        uint256 tokenId = _buyTicketForSeller();
        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, 60 * 1e6);

        vm.prank(reseller);
        vm.expectRevert(NFTMarketplace.NotSeller.selector);
        marketplace.cancel(listingId);
    }

    function test_buy_success() public {
        uint256 tokenId   = _buyTicketForSeller();
        uint256 listPrice = 60 * 1e6;

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, listPrice);

        vm.prank(reseller);
        usdc.approve(address(marketplace), listPrice);

        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 orgBefore    = usdc.balanceOf(organizer);
        uint256 treasBefore  = usdc.balanceOf(treasury);

        vm.prank(reseller);
        marketplace.buyWithUSDC(listingId);

        assertEq(nft.ownerOf(tokenId), reseller);

        uint256 royalty = listPrice * 500 / 10_000;
        assertEq(usdc.balanceOf(organizer), orgBefore + royalty);

        uint256 fee = listPrice * 700 / 10_000;
        assertEq(usdc.balanceOf(treasury), treasBefore + fee);
        assertEq(usdc.balanceOf(seller), sellerBefore + listPrice - royalty - fee);

        (, , , , bool active) = _getListing(listingId);
        assertFalse(active);
    }

    function test_buy_inactiveListing_reverts() public {
        uint256 tokenId = _buyTicketForSeller();
        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, 60 * 1e6);

        vm.prank(seller);
        marketplace.cancel(listingId);

        vm.prank(reseller);
        usdc.approve(address(marketplace), 60 * 1e6);

        vm.prank(reseller);
        vm.expectRevert(NFTMarketplace.ListingInactive.selector);
        marketplace.buyWithUSDC(listingId);
    }

    function test_buy_afterRedeemBlocked() public {
        uint256 tokenId   = _buyTicketForSeller();
        uint256 listPrice = 60 * 1e6;

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, listPrice);

        vm.warp(nft.eventDate() - 12 hours);
        bytes memory sig = _signRedeem(venueSignerPk, address(nft), tokenId);
        vm.prank(seller);
        nft.redeem(tokenId, sig);

        vm.prank(reseller);
        usdc.approve(address(marketplace), listPrice);
        vm.prank(reseller);
        vm.expectRevert(NFTMarketplace.AlreadyRedeemed.selector);
        marketplace.buyWithUSDC(listingId);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Fuzz
    // ══════════════════════════════════════════════════════════════════════════

    function testFuzz_listPrice_clampedByCap(uint256 rawPrice) public {
        vm.prank(seller);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(seller);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);

        uint256 trueCap = nft.maxResalePrice(tokenId);
        uint256 price   = bound(rawPrice, trueCap + 1, trueCap * 10);

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);

        vm.prank(seller);
        vm.expectRevert();
        marketplace.list(address(nft), tokenId, price);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════════

    function _getListing(uint256 id) internal view
        returns (address seller_, address eventNFT, uint256 tokenId, uint256 price, bool active)
    {
        NFTMarketplace.Listing memory l = marketplace.getListing(id);
        return (l.seller, l.eventNFT, l.tokenId, l.priceUSDC, l.active);
    }

    function _signRedeem(uint256 pk, address eventNFT, uint256 tokenId)
        internal view returns (bytes memory)
    {
        bytes32 payload = keccak256(abi.encode(eventNFT, tokenId, block.chainid));
        bytes32 ethMsg  = MessageHashUtils.toEthSignedMessageHash(payload);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethMsg);
        return abi.encodePacked(r, s, v);
    }
}

// ══════════════════════════════════════════════════════════════════════════
// Admin tests — OfferingNFT y NFTMarketplace (coverage)
// ══════════════════════════════════════════════════════════════════════════

contract AdminCoverageTest is Test, ERC721Holder {

    address admin     = makeAddr("admin2");
    address organizer = makeAddr("organizer2");
    address treasury  = makeAddr("treasury2");
    address buyer     = makeAddr("buyer2");
    address seller    = makeAddr("seller2");
    address stranger  = makeAddr("stranger2");

    uint256 venueSignerPk = 0x1338;
    address venueSigner   = vm.addr(0x1338);

    MockERC20         usdc;
    MockERC20         vbk;
    MockUniswapRouter router;
    EventFactory      factory;
    OfferingNFT       offering;
    NFTMarketplace    marketplace;
    EventNFT          nft;

    uint256 constant PRICE_USDC = 50 * 1e6;
    uint256 constant EVENT_DATE = 30 days;

    function setUp() public {
        usdc   = new MockERC20("USDC", "USDC", 6);
        vbk    = new MockERC20("VBK",  "VBK",  18);
        router = new MockUniswapRouter();

        vm.prank(admin);
        factory = new EventFactory(admin, address(usdc), address(vbk), address(router), treasury);
        vm.prank(admin);
        offering = new OfferingNFT(admin, factory, treasury);
        vm.prank(admin);
        marketplace = new NFTMarketplace(admin, factory, treasury);

        vm.startPrank(admin);
        factory.setOffering(address(offering));
        factory.setMarketplace(address(marketplace));
        vm.stopPrank();

        EventFactory.EventParams memory p = EventFactory.EventParams({
            name: "Admin Coverage Event",
            symbol: "ADMC",
            eventDate: block.timestamp + EVENT_DATE,
            maxResalePriceBps: 15_000,
            royaltyBps: 500,
            venueSigner: venueSigner,
            baseURI: "ipfs://admin/"
        });
        EventNFT.Tier[] memory t = new EventNFT.Tier[](1);
        t[0] = EventNFT.Tier("General", PRICE_USDC, 100, 0);

        // Cualquier wallet puede lanzar — sin grantOrganizer
        vm.prank(organizer);
        nft = EventNFT(factory.launchEvent(p, t));

        usdc.mint(buyer,   1_000 * 1e6);
        usdc.mint(seller,  1_000 * 1e6);
        vbk.mint(buyer,    1_000_000 * 1e18);
    }

    // ── OfferingNFT admin ───────────────────────────────────────────────

    function test_setPlatformFeeUSDC_success() public {
        vm.prank(admin);
        offering.setPlatformFeeUSDC(300);
        assertEq(offering.platformFeeBpsUSDC(), 300);
    }

    function test_setPlatformFeeUSDC_aboveMax_reverts() public {
        vm.prank(admin);
        vm.expectRevert(OfferingNFT.FeeAboveMax.selector);
        offering.setPlatformFeeUSDC(1001);
    }

    function test_setPlatformFeeUSDC_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        offering.setPlatformFeeUSDC(300);
    }

    function test_setPlatformFeeVBK_success() public {
        vm.prank(admin);
        offering.setPlatformFeeVBK(100);
        assertEq(offering.platformFeeBpsVBK(), 100);
    }

    function test_setPlatformFeeVBK_aboveMax_reverts() public {
        vm.prank(admin);
        vm.expectRevert(OfferingNFT.FeeAboveMax.selector);
        offering.setPlatformFeeVBK(1001);
    }

    function test_setPlatformFeeVBK_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        offering.setPlatformFeeVBK(100);
    }

    function test_offering_unpause() public {
        vm.prank(admin);
        offering.pause();
        vm.prank(admin);
        offering.unpause();

        vm.prank(buyer);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(buyer);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);
        assertEq(tokenId, 1);
    }

    // ── NFTMarketplace admin ────────────────────────────────────────────

    function test_setResaleFee_success() public {
        vm.prank(admin);
        marketplace.setResaleFeeUSDC(500);
        assertEq(marketplace.resaleFeeBpsUSDC(), 500);
    }

    function test_setResaleFee_aboveMax_reverts() public {
        vm.prank(admin);
        vm.expectRevert(NFTMarketplace.FeeAboveMax.selector);
        marketplace.setResaleFeeUSDC(2001);
    }

    function test_setResaleFee_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        marketplace.setResaleFeeUSDC(500);
    }

    function test_marketplace_pause_blocksList() public {
        vm.prank(seller);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(seller);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);

        vm.prank(admin);
        marketplace.pause();

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);

        vm.prank(seller);
        vm.expectRevert();
        marketplace.list(address(nft), tokenId, 60 * 1e6);
    }

    function test_marketplace_unpause() public {
        vm.prank(admin);
        marketplace.pause();
        vm.prank(admin);
        marketplace.unpause();

        vm.prank(seller);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(seller);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, 60 * 1e6);
        assertTrue(marketplace.getListing(listingId).active);
    }

    function test_marketplace_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        marketplace.pause();
    }

    function test_buy_eventOver_afterListing() public {
        vm.prank(seller);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(seller);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, 60 * 1e6);

        vm.warp(block.timestamp + EVENT_DATE + 1);

        vm.prank(buyer);
        usdc.approve(address(marketplace), 60 * 1e6);
        vm.prank(buyer);
        vm.expectRevert(NFTMarketplace.EventOver.selector);
        marketplace.buyWithUSDC(listingId);
    }

    function test_list_notOwner_reverts() public {
        vm.prank(seller);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(seller);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);

        vm.prank(stranger);
        vm.expectRevert(NFTMarketplace.NotOwner.selector);
        marketplace.list(address(nft), tokenId, 60 * 1e6);
    }

    function test_list_alreadyRedeemed_reverts() public {
        vm.prank(seller);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(seller);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);

        vm.warp(nft.eventDate() - 12 hours);
        bytes32 payload = keccak256(abi.encode(address(nft), tokenId, block.chainid));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(venueSignerPk,
            MessageHashUtils.toEthSignedMessageHash(payload));
        vm.prank(seller);
        nft.redeem(tokenId, abi.encodePacked(r, s, v));

        vm.prank(seller);
        vm.expectRevert(NFTMarketplace.AlreadyRedeemed.selector);
        marketplace.list(address(nft), tokenId, 60 * 1e6);
    }

    function test_cancel_inactiveListing_reverts() public {
        vm.prank(seller);
        usdc.approve(address(offering), PRICE_USDC);
        vm.prank(seller);
        uint256 tokenId = offering.buyWithUSDC(address(nft), 0);

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, 60 * 1e6);

        vm.prank(seller);
        marketplace.cancel(listingId);

        vm.prank(seller);
        vm.expectRevert(NFTMarketplace.ListingInactive.selector);
        marketplace.cancel(listingId);
    }
}
