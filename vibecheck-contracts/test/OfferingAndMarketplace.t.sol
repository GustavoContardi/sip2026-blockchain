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
    // ratio: 1 USDC = 10 VBK (precio fijo para tests)
    uint256 public constant RATIO = 10;

    function getAmountsOut(uint256 amountIn, address[] calldata)
        external pure returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * RATIO;
    }
}

contract OfferingAndMarketplaceTest is Test, ERC721Holder {
    // ─── Actores ───────────────────────────────────────────────────────────────
    address admin     = makeAddr("admin");
    address organizer = makeAddr("organizer");
    address treasury  = makeAddr("treasury");
    address buyer     = makeAddr("buyer");
    address seller    = makeAddr("seller");
    address reseller  = makeAddr("reseller");

    uint256 venueSignerPk = 0x1337;
    address venueSigner   = vm.addr(venueSignerPk);

    // ─── Contratos ─────────────────────────────────────────────────────────────
    MockERC20         public usdc;
    MockERC20         public vbk;
    MockUniswapRouter public router;
    EventFactory      public factory;
    OfferingNFT       public offering;
    NFTMarketplace    public marketplace;
    EventNFT          public nft;

    uint256 constant PRICE_USDC = 50 * 1e6;   // 50 USDC (6 dec)
    uint256 constant EVENT_DATE = 30 days;     // relativo a block.timestamp en setUp

    function setUp() public {
        usdc   = new MockERC20("USDC", "USDC", 6);
        vbk    = new MockERC20("VBK", "VBK", 18);
        router = new MockUniswapRouter();

        // Factory
        vm.prank(admin);
        factory = new EventFactory(admin, address(usdc), address(vbk), address(router), treasury);

        // Offering y Marketplace
        vm.prank(admin);
        offering = new OfferingNFT(admin, factory, treasury);
        vm.prank(admin);
        marketplace = new NFTMarketplace(admin, factory, treasury);

        // Bootstrap
        vm.startPrank(admin);
        factory.setOffering(address(offering));
        factory.setMarketplace(address(marketplace));
        factory.grantOrganizer(organizer);
        vm.stopPrank();

        // Lanzar evento
        EventFactory.EventParams memory p = EventFactory.EventParams({
            name: "Festival Test",
            symbol: "FEST",
            eventDate: block.timestamp + EVENT_DATE,
            maxResalePriceBps: 15_000, // 150% tope
            royaltyBps: 500,
            venueSigner: venueSigner,
            baseURI: "ipfs://test/"
        });

        EventNFT.Tier[] memory t = new EventNFT.Tier[](1);
        t[0] = EventNFT.Tier({name: "General", priceUSDC: PRICE_USDC, supply: 100, sold: 0});

        vm.prank(organizer);
        address nftAddr = factory.launchEvent(p, t);
        nft = EventNFT(nftAddr);

        // Fondear buyer y seller con USDC/VBK
        usdc.mint(buyer,   1_000 * 1e6);
        usdc.mint(seller,  1_000 * 1e6);
        usdc.mint(reseller, 1_000 * 1e6);
        vbk.mint(buyer,    1_000_000 * 1e18);
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

        // Fee 5% al treasury, neto al organizer
        uint256 fee = PRICE_USDC * 500 / 10_000;
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(organizer), PRICE_USDC - fee);
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
        // 50 USDC * 10 = 500 VBK (ratio del mock router)
        uint256 vbkNeeded = PRICE_USDC * 10;
        uint256 maxVbk    = vbkNeeded * 110 / 100; // 10% slippage buffer

        vm.prank(buyer);
        vbk.approve(address(offering), maxVbk);

        vm.prank(buyer);
        uint256 tokenId = offering.buyWithVBK(address(nft), 0, maxVbk);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), buyer);

        // Fee 2% (VBK), neto al organizer
        uint256 fee = vbkNeeded * 200 / 10_000;
        assertEq(vbk.balanceOf(treasury), fee);
        assertEq(vbk.balanceOf(organizer), vbkNeeded - fee);

        // originalPrice guardado es en USDC, no VBK
        assertEq(nft.originalPrice(1), PRICE_USDC);
    }

    function test_buyWithVBK_slippageTooHigh_reverts() public {
        uint256 vbkNeeded = PRICE_USDC * 10;
        uint256 maxVbk    = vbkNeeded - 1; // 1 wei menos del necesario

        vm.prank(buyer);
        vbk.approve(address(offering), vbkNeeded);

        vm.prank(buyer);
        vm.expectRevert();
        offering.buyWithVBK(address(nft), 0, maxVbk);
    }

    function test_buyWithVBK_feeDiscount() public {
        // VBK fee (2%) < USDC fee (5%)
        assertLt(offering.platformFeeBpsVBK(), offering.platformFeeBpsUSDC());
    }

    function test_quoteVBK() public view {
        uint256 quote = offering.quoteVBK(address(nft), 0);
        assertEq(quote, PRICE_USDC * 10); // ratio mock = 10
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
        uint256 tokenId = _buyTicketForSeller();
        uint256 listPrice = 60 * 1e6; // 60 USDC (< 150% de 50 = 75)

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);

        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, listPrice);

        (address s, address e, uint256 t, uint256 p, bool active) =
            _getListing(listingId);
        assertEq(s, seller);
        assertEq(e, address(nft));
        assertEq(t, tokenId);
        assertEq(p, listPrice);
        assertTrue(active);
    }

    function test_list_priceAboveCap_reverts() public {
        uint256 tokenId = _buyTicketForSeller();
        uint256 overCap = 80 * 1e6; // 80 USDC > 75 USDC (150% de 50)

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
        marketplace.buy(listingId);

        // NFT al nuevo owner
        assertEq(nft.ownerOf(tokenId), reseller);

        // Royalty 5%
        uint256 royalty = listPrice * 500 / 10_000; // 3 USDC
        assertEq(usdc.balanceOf(organizer), orgBefore + royalty);

        // Fee plataforma 10%
        uint256 fee = listPrice * 1_000 / 10_000; // 6 USDC
        assertEq(usdc.balanceOf(treasury), treasBefore + fee);

        // Seller recibe el resto
        assertEq(usdc.balanceOf(seller), sellerBefore + listPrice - royalty - fee);

        // Listing inactivo
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
        marketplace.buy(listingId);
    }

    function test_buy_afterRedeemBlocked() public {
        uint256 tokenId   = _buyTicketForSeller();
        uint256 listPrice = 60 * 1e6;

        vm.prank(seller);
        nft.approve(address(marketplace), tokenId);
        vm.prank(seller);
        uint256 listingId = marketplace.list(address(nft), tokenId, listPrice);

        // Redimir el ticket
        vm.warp(nft.eventDate() - 12 hours);
        bytes memory sig = _signRedeem(venueSignerPk, address(nft), tokenId);
        vm.prank(seller);
        nft.redeem(tokenId, sig);

        // Comprar → debe revertir
        vm.prank(reseller);
        usdc.approve(address(marketplace), listPrice);
        vm.prank(reseller);
        vm.expectRevert(NFTMarketplace.AlreadyRedeemed.selector);
        marketplace.buy(listingId);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Fuzz
    // ══════════════════════════════════════════════════════════════════════════

    function testFuzz_listPrice_clampedByCap(uint256 rawPrice) public {
        uint256 cap = nft.maxResalePrice(0); // usa originalPrice=0 → cap=0
        // Mintear para tener tokenId 1 con originalPrice real
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
