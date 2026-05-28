// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {EventNFT} from "../src/EventNFT.sol";
import {EventFactory} from "../src/EventFactory.sol";

contract EventNFTAndFactoryTest is Test {
    using ECDSA for bytes32;

    // ─── Actores ───────────────────────────────────────────────────────────────
    address admin      = makeAddr("admin");
    address organizer  = makeAddr("organizer");
    address buyer      = makeAddr("buyer");
    address stranger   = makeAddr("stranger");
    address minter     = makeAddr("minter");    // simula OfferingNFT
    address market     = makeAddr("market");    // simula NFTMarketplace

    uint256 venueSignerPk = 0xABCDEF;
    address venueSigner   = vm.addr(venueSignerPk);

    // ─── Contratos ─────────────────────────────────────────────────────────────
    EventFactory public factory;
    EventNFT     public nft;

    // ─── Helpers ───────────────────────────────────────────────────────────────
    address constant USDC    = address(0xC0FFEE);
    address constant VBK     = address(0xBEEF);
    address constant ROUTER  = address(0xDEAD);
    address constant TREASURY = address(0xFEE);

    EventFactory.EventParams eventParams;
    EventNFT.Tier[] tiers;

    function setUp() public {
        // Deploy factory
        vm.prank(admin);
        factory = new EventFactory(admin, USDC, VBK, ROUTER, TREASURY);

        // Autorizar al minter (simula OfferingNFT) y marketplace
        vm.startPrank(admin);
        factory.setOffering(minter);
        factory.setMarketplace(market);
        factory.grantOrganizer(organizer);
        vm.stopPrank();

        // Parámetros base del evento
        eventParams = EventFactory.EventParams({
            name: "Recital Test",
            symbol: "TST",
            eventDate: block.timestamp + 7 days,
            maxResalePriceBps: 12_000,
            royaltyBps: 500,
            venueSigner: venueSigner,
            baseURI: "ipfs://QmTest/"
        });

        tiers.push(EventNFT.Tier({name: "VIP",     priceUSDC: 100 * 1e6, supply: 50,  sold: 0}));
        tiers.push(EventNFT.Tier({name: "General", priceUSDC:  50 * 1e6, supply: 500, sold: 0}));

        // Lanzar evento
        vm.prank(organizer);
        address nftAddr = factory.launchEvent(eventParams, tiers);
        nft = EventNFT(nftAddr);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventFactory
    // ══════════════════════════════════════════════════════════════════════════

    function test_factory_onlyOrganizerCanLaunch() public {
        vm.prank(stranger);
        vm.expectRevert();
        factory.launchEvent(eventParams, tiers);
    }

    function test_factory_registersEvent() public view {
        assertEq(factory.eventsLength(), 1);
        assertTrue(factory.isEvent(address(nft)));
    }

    function test_factory_grantRoles() public view {
        assertTrue(nft.hasRole(nft.MINTER_ROLE(), minter));
        assertTrue(nft.hasRole(nft.MARKET_ROLE(), market));
    }

    function test_factory_setOffering_onlyOnce() public {
        vm.prank(admin);
        vm.expectRevert(EventFactory.AlreadySet.selector);
        factory.setOffering(address(0x1234));
    }

    function test_factory_setMarketplace_onlyOnce() public {
        vm.prank(admin);
        vm.expectRevert(EventFactory.AlreadySet.selector);
        factory.setMarketplace(address(0x1234));
    }

    function test_factory_requiresInfraBeforeLaunch() public {
        // Factory nueva sin setOffering ni setMarketplace
        vm.prank(admin);
        EventFactory bareFactory = new EventFactory(admin, USDC, VBK, ROUTER, TREASURY);
        vm.prank(admin);
        bareFactory.grantOrganizer(organizer);

        vm.prank(organizer);
        vm.expectRevert(EventFactory.InfraNotReady.selector);
        bareFactory.launchEvent(eventParams, tiers);
    }

    function test_factory_revokeOrganizer() public {
        vm.prank(admin);
        factory.revokeOrganizer(organizer);

        vm.prank(organizer);
        vm.expectRevert();
        factory.launchEvent(eventParams, tiers);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventNFT — constructor y estado
    // ══════════════════════════════════════════════════════════════════════════

    function test_nft_immutableParams() public view {
        assertEq(nft.organizer(), organizer);
        assertEq(nft.eventDate(), block.timestamp + 7 days);
        assertEq(nft.maxResalePriceBps(), 12_000);
        assertEq(nft.royaltyBps(), 500);
        assertEq(nft.venueSigner(), venueSigner);
        assertEq(nft.tiersLength(), 2);
    }

    function test_nft_royaltyInfo() public view {
        // Mintear primero para tener un tokenId válido
        // Chequeamos solo el royaltyInfo default (no necesita tokenId existente)
        (address receiver, uint256 amount) = nft.royaltyInfo(0, 100 * 1e6);
        assertEq(receiver, organizer);
        assertEq(amount, 100 * 1e6 * 500 / 10_000); // 5%
    }

    function test_nft_invalidResaleCap_reverts() public {
        EventNFT.InitParams memory p = EventNFT.InitParams({
            name: "X", symbol: "X", organizer: organizer,
            eventDate: block.timestamp + 1 days,
            maxResalePriceBps: 9_999, // < 10000 → inválido
            royaltyBps: 500,
            venueSigner: venueSigner,
            baseURI: ""
        });
        EventNFT.Tier[] memory t = new EventNFT.Tier[](1);
        t[0] = EventNFT.Tier("A", 10 * 1e6, 10, 0);

        vm.expectRevert(EventNFT.InvalidResaleCap.selector);
        new EventNFT(p, t);
    }

    function test_nft_invalidRoyalty_reverts() public {
        EventNFT.InitParams memory p = EventNFT.InitParams({
            name: "X", symbol: "X", organizer: organizer,
            eventDate: block.timestamp + 1 days,
            maxResalePriceBps: 12_000,
            royaltyBps: 2_001, // > 2000 → inválido
            venueSigner: venueSigner,
            baseURI: ""
        });
        EventNFT.Tier[] memory t = new EventNFT.Tier[](1);
        t[0] = EventNFT.Tier("A", 10 * 1e6, 10, 0);

        vm.expectRevert(EventNFT.InvalidRoyalty.selector);
        new EventNFT(p, t);
    }

    function test_nft_eventDateInPast_reverts() public {
        EventNFT.InitParams memory p = EventNFT.InitParams({
            name: "X", symbol: "X", organizer: organizer,
            eventDate: block.timestamp - 1,
            maxResalePriceBps: 12_000,
            royaltyBps: 500,
            venueSigner: venueSigner,
            baseURI: ""
        });
        EventNFT.Tier[] memory t = new EventNFT.Tier[](1);
        t[0] = EventNFT.Tier("A", 10 * 1e6, 10, 0);

        vm.expectRevert(EventNFT.EventDateInPast.selector);
        new EventNFT(p, t);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventNFT — mintTicket
    // ══════════════════════════════════════════════════════════════════════════

    function test_mintTicket_onlyMinterRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.mintTicket(buyer, 0, 100 * 1e6);
    }

    function test_mintTicket_success() public {
        vm.prank(minter);
        uint256 tokenId = nft.mintTicket(buyer, 0, 100 * 1e6);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(nft.tokenTier(1), 0);
        assertEq(nft.originalPrice(1), 100 * 1e6);
        assertEq(nft.totalMinted(), 1);

        (, , , uint256 sold) = nft.tiers(0);
        assertEq(sold, 1);
    }

    function test_mintTicket_soldOut_reverts() public {
        // tier 0 tiene supply 50; mintear 50+1
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(minter);
            nft.mintTicket(makeAddr(string(abi.encode(i))), 0, 100 * 1e6);
        }
        vm.prank(minter);
        vm.expectRevert(EventNFT.TierSoldOut.selector);
        nft.mintTicket(buyer, 0, 100 * 1e6);
    }

    function test_mintTicket_invalidTier_reverts() public {
        vm.prank(minter);
        vm.expectRevert(EventNFT.TierOutOfRange.selector);
        nft.mintTicket(buyer, 99, 100 * 1e6);
    }

    function test_mintTicket_revertAfterEventDate() public {
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(minter);
        vm.expectRevert(EventNFT.EventOver.selector);
        nft.mintTicket(buyer, 0, 100 * 1e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventNFT — soulbound parcial
    // ══════════════════════════════════════════════════════════════════════════

    function test_directTransfer_blocked() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        // buyer intenta transferir directamente → revert
        vm.prank(buyer);
        vm.expectRevert(EventNFT.TransferNotAllowed.selector);
        nft.transferFrom(buyer, stranger, 1);
    }

    function test_marketRole_canTransfer() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        // Aprobar al marketplace
        vm.prank(buyer);
        nft.approve(market, 1);

        // marketplace puede mover
        vm.prank(market);
        nft.transferFrom(buyer, stranger, 1);
        assertEq(nft.ownerOf(1), stranger);
    }

    function test_transfer_blockedAfterRedeem() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        // Redimir
        vm.warp(nft.eventDate() - 12 hours);
        bytes memory sig = _signRedeem(venueSignerPk, address(nft), 1);
        vm.prank(buyer);
        nft.redeem(1, sig);

        // Intentar transferir post-redeem
        vm.prank(buyer);
        vm.expectRevert(EventNFT.TransferNotAllowed.selector);
        nft.transferFrom(buyer, stranger, 1);
    }

    function test_transfer_blockedAfterEventDate() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        vm.warp(nft.eventDate() + 1);

        vm.prank(buyer);
        vm.expectRevert(EventNFT.TransferNotAllowed.selector);
        nft.transferFrom(buyer, stranger, 1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventNFT — redeem
    // ══════════════════════════════════════════════════════════════════════════

    function test_redeem_success() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        vm.warp(nft.eventDate() - 12 hours);
        bytes memory sig = _signRedeem(venueSignerPk, address(nft), 1);

        vm.prank(buyer);
        nft.redeem(1, sig);

        assertTrue(nft.redeemed(1));
        assertTrue(nft.attended(1));
    }

    function test_redeem_invalidSignature_reverts() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        vm.warp(nft.eventDate() - 12 hours);

        // Firmar con clave incorrecta
        bytes memory badSig = _signRedeem(0xDEADBEEF, address(nft), 1);
        vm.prank(buyer);
        vm.expectRevert(EventNFT.InvalidSignature.selector);
        nft.redeem(1, badSig);
    }

    function test_redeem_alreadyRedeemed_reverts() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        vm.warp(nft.eventDate() - 12 hours);
        bytes memory sig = _signRedeem(venueSignerPk, address(nft), 1);

        vm.prank(buyer);
        nft.redeem(1, sig);

        vm.prank(buyer);
        vm.expectRevert(EventNFT.AlreadyRedeemed.selector);
        nft.redeem(1, sig);
    }

    function test_redeem_outsideWindow_reverts() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        // Fuera de ventana: mucho antes del evento
        vm.warp(nft.eventDate() - 2 days);
        bytes memory sig = _signRedeem(venueSignerPk, address(nft), 1);

        vm.prank(buyer);
        vm.expectRevert(EventNFT.CheckInWindowClosed.selector);
        nft.redeem(1, sig);
    }

    function test_redeem_notOwner_reverts() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        vm.warp(nft.eventDate() - 12 hours);
        bytes memory sig = _signRedeem(venueSignerPk, address(nft), 1);

        vm.prank(stranger);
        vm.expectRevert(EventNFT.TransferNotAllowed.selector);
        nft.redeem(1, sig);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventNFT — tokenURI dinámico
    // ══════════════════════════════════════════════════════════════════════════

    function test_tokenURI_preRedeem() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        string memory uri = nft.tokenURI(1);
        assertEq(uri, "ipfs://QmTest/ticket/1");
    }

    function test_tokenURI_postRedeem() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        vm.warp(nft.eventDate() - 12 hours);
        bytes memory sig = _signRedeem(venueSignerPk, address(nft), 1);
        vm.prank(buyer);
        nft.redeem(1, sig);

        string memory uri = nft.tokenURI(1);
        assertEq(uri, "ipfs://QmTest/collectible/1");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventNFT — maxResalePrice
    // ══════════════════════════════════════════════════════════════════════════

    function test_maxResalePrice() public {
        vm.prank(minter);
        nft.mintTicket(buyer, 0, 100 * 1e6);

        uint256 cap = nft.maxResalePrice(1);
        // 100 USDC * 12000 / 10000 = 120 USDC
        assertEq(cap, 120 * 1e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════════

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
// EventNFT — funciones admin (coverage)
// ══════════════════════════════════════════════════════════════════════════

contract EventNFTAdminTest is Test {
    using MessageHashUtils for bytes32;

    address admin     = makeAddr("admin");
    address organizer = makeAddr("organizer");
    address minter    = makeAddr("minter");
    address market    = makeAddr("market");
    address stranger  = makeAddr("stranger");

    uint256 venueSignerPk  = 0xABCDEF;
    uint256 newSignerPk    = 0x999;
    address venueSigner    = vm.addr(0xABCDEF);
    address newVenueSigner = vm.addr(0x999);

    address constant USDC   = address(0xC0FFEE);
    address constant VBK    = address(0xBEEF);
    address constant ROUTER = address(0xDEAD);
    address constant TREASURY = address(0xFEE);

    EventFactory factory;
    EventNFT     nft;

    function setUp() public {
        vm.prank(admin);
        factory = new EventFactory(admin, USDC, VBK, ROUTER, TREASURY);

        vm.startPrank(admin);
        factory.setOffering(minter);
        factory.setMarketplace(market);
        factory.grantOrganizer(organizer);
        vm.stopPrank();

        EventFactory.EventParams memory p = EventFactory.EventParams({
            name: "Admin Test Event",
            symbol: "ADM",
            eventDate: block.timestamp + 7 days,
            maxResalePriceBps: 12_000,
            royaltyBps: 500,
            venueSigner: venueSigner,
            baseURI: "ipfs://QmAdmin/"
        });
        EventNFT.Tier[] memory t = new EventNFT.Tier[](1);
        t[0] = EventNFT.Tier("VIP", 100 * 1e6, 50, 0);

        vm.prank(organizer);
        nft = EventNFT(factory.launchEvent(p, t));
    }

    // ── setVenueSigner ──────────────────────────────────────────────────

    function test_setVenueSigner_success() public {
        vm.prank(organizer);
        nft.setVenueSigner(newVenueSigner);
        assertEq(nft.venueSigner(), newVenueSigner);
    }

    function test_setVenueSigner_zeroAddress_reverts() public {
        vm.prank(organizer);
        vm.expectRevert(EventNFT.ZeroAddress.selector);
        nft.setVenueSigner(address(0));
    }

    function test_setVenueSigner_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.setVenueSigner(newVenueSigner);
    }

    function test_setVenueSigner_redeemWithNewSigner() public {
        // Cambiar el signer y verificar que redeem funciona con la nueva clave
        vm.prank(organizer);
        nft.setVenueSigner(newVenueSigner);

        vm.prank(minter);
        nft.mintTicket(makeAddr("buyer"), 0, 100 * 1e6);

        vm.warp(nft.eventDate() - 12 hours);
        bytes32 payload = keccak256(abi.encode(address(nft), uint256(1), block.chainid));
        bytes32 ethMsg  = MessageHashUtils.toEthSignedMessageHash(payload);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newSignerPk, ethMsg);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(makeAddr("buyer"));
        nft.redeem(1, sig);
        assertTrue(nft.redeemed(1));
    }

    // ── setBaseURI ──────────────────────────────────────────────────────

    function test_setBaseURI_success() public {
        vm.prank(minter);
        nft.mintTicket(makeAddr("buyer"), 0, 100 * 1e6);

        vm.prank(organizer);
        nft.setBaseURI("ipfs://QmNewBase/");

        assertEq(nft.tokenURI(1), "ipfs://QmNewBase/ticket/1");
    }

    function test_setBaseURI_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.setBaseURI("ipfs://hack/");
    }

    function test_setBaseURI_empty_returnsEmpty() public {
        vm.prank(minter);
        nft.mintTicket(makeAddr("buyer"), 0, 100 * 1e6);

        vm.prank(organizer);
        nft.setBaseURI("");

        assertEq(nft.tokenURI(1), "");
    }

    // ── pause / unpause ─────────────────────────────────────────────────

    function test_nft_pause_blocksMint() public {
        vm.prank(organizer);
        nft.pause();

        vm.prank(minter);
        vm.expectRevert();
        nft.mintTicket(makeAddr("buyer"), 0, 100 * 1e6);
    }

    function test_nft_unpause_resumesMint() public {
        vm.prank(organizer);
        nft.pause();
        vm.prank(organizer);
        nft.unpause();

        vm.prank(minter);
        uint256 tokenId = nft.mintTicket(makeAddr("buyer"), 0, 100 * 1e6);
        assertEq(tokenId, 1);
    }

    function test_nft_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.pause();
    }

    // ── supportsInterface ───────────────────────────────────────────────

    function test_supportsInterface_ERC721() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
    }

    function test_supportsInterface_ERC2981() public view {
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC-2981 royalty
    }

    function test_supportsInterface_AccessControl() public view {
        assertTrue(nft.supportsInterface(0x7965db0b)); // AccessControl
    }
}
