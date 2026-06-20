// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {RewardsVault} from "../src/RewardsVault.sol";

// ─── Mocks ─────────────────────────────────────────────────────────────────

/// @notice Mock de EventFactory: el admin decide a mano qué addresses
///         son "eventos válidos", sin necesidad de deployar la factory real.
contract MockFactory {
    mapping(address => bool) public isEvent_;

    function setEvent(address nft, bool ok) external {
        isEvent_[nft] = ok;
    }

    function isEvent(address nft) external view returns (bool) {
        return isEvent_[nft];
    }
}

/// @notice Mock del router Uniswap V2. Ratio configurable, y puede simular
///         "pool sin liquidez" revirtiendo getAmountsOut.
contract MockRouter {
    uint256 public ratio = 10; // 1 USDC = 10 VBK, por defecto
    bool    public shouldRevert;

    function setRatio(uint256 r) external {
        ratio = r;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        if (shouldRevert) revert("no liquidity");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[amounts.length - 1] = amountIn * ratio;
    }
}

/// @notice Mock de ERC20 (VBK) con transferFrom controlable: puede fallar
///         por allowance insuficiente (revert estándar), devolver false
///         sin revertir, o revertir con mensaje custom.
contract MockVBK {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool   public returnFalse;
    bool   public revertWithMessage;
    string public revertMessage = "VBK: insufficient allowance";

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function setReturnFalse(bool v) external {
        returnFalse = v;
    }

    function setRevertWithMessage(bool v) external {
        revertWithMessage = v;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (revertWithMessage) revert(revertMessage);
        if (returnFalse) return false;

        require(allowance[from][msg.sender] >= amt, "allowance");
        require(balanceOf[from] >= amt, "balance");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

contract RewardsVaultTest is Test {
    RewardsVault public vault;
    MockFactory  public factory;
    MockRouter   public router;
    MockVBK      public vbk;

    address admin    = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address fan      = makeAddr("fan");
    address stranger = makeAddr("stranger");

    address constant USDC = address(0xC0FFEE);

    // Evento "legítimo": en estos tests simulamos al EventNFT con una
    // wallet común, registrada en MockFactory. Lo que importa es que
    // msg.sender == esa address cuando se llama notifyRedeem.
    address eventNFT = makeAddr("eventNFT");

    uint256 constant REWARD_USDC = 0.10e6; // default del contrato

    function setUp() public {
        factory = new MockFactory();
        router  = new MockRouter();
        vbk     = new MockVBK();

        vm.prank(admin);
        vault = new RewardsVault(admin, address(factory), address(router), USDC, address(vbk), treasury);

        factory.setEvent(eventNFT, true);

        vbk.mint(treasury, 1_000_000e18);
        vm.prank(treasury);
        vbk.approve(address(vault), type(uint256).max);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Constructor
    // ══════════════════════════════════════════════════════════════════════

    function test_constructor_setsState() public view {
        assertEq(vault.owner(), admin);
        assertEq(address(vault.factory()), address(factory));
        assertEq(address(vault.router()), address(router));
        assertEq(vault.usdc(), USDC);
        assertEq(vault.vbk(), address(vbk));
        assertEq(vault.treasury(), treasury);
        assertEq(vault.rewardUSDC(), REWARD_USDC);
    }

    function test_constructor_zeroAdmin_reverts() public {
        // admin == address(0) revierte en Ownable(admin), antes de llegar
        // al cuerpo del constructor de RewardsVault. El error viene de
        // OpenZeppelin, no de nuestro ZeroAddress() custom.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RewardsVault(address(0), address(factory), address(router), USDC, address(vbk), treasury);
    }

    function test_constructor_zeroFactory_reverts() public {
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        new RewardsVault(admin, address(0), address(router), USDC, address(vbk), treasury);
    }

    function test_constructor_zeroRouter_reverts() public {
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        new RewardsVault(admin, address(factory), address(0), USDC, address(vbk), treasury);
    }

    function test_constructor_zeroUsdc_reverts() public {
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        new RewardsVault(admin, address(factory), address(router), address(0), address(vbk), treasury);
    }

    function test_constructor_zeroVbk_reverts() public {
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        new RewardsVault(admin, address(factory), address(router), USDC, address(0), treasury);
    }

    function test_constructor_zeroTreasury_reverts() public {
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        new RewardsVault(admin, address(factory), address(router), USDC, address(vbk), address(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    // notifyRedeem — camino feliz
    // ══════════════════════════════════════════════════════════════════════

    function test_notifyRedeem_paysReward() public {
        uint256 expectedVbk = REWARD_USDC * router.ratio(); // 1 USDC = 10 VBK

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);

        assertEq(vbk.balanceOf(fan), expectedVbk);
        assertTrue(vault.rewardPaid(eventNFT, 1));
    }

    function test_notifyRedeem_emitsRewardPaid() public {
        uint256 expectedVbk = REWARD_USDC * router.ratio();

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsVault.RewardPaid(eventNFT, 1, fan, expectedVbk);

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);
    }

    function test_notifyRedeem_usesRouterRatio() public {
        router.setRatio(25); // 1 USDC = 25 VBK

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);

        assertEq(vbk.balanceOf(fan), REWARD_USDC * 25);
    }

    function test_notifyRedeem_pullsFromTreasuryNotCaller() public {
        uint256 treasuryBefore = vbk.balanceOf(treasury);

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);

        uint256 paid = vbk.balanceOf(fan);
        assertEq(vbk.balanceOf(treasury), treasuryBefore - paid);
    }

    // ══════════════════════════════════════════════════════════════════════
    // notifyRedeem — control de acceso (factory.isEvent)
    // ══════════════════════════════════════════════════════════════════════

    function test_notifyRedeem_unknownCaller_reverts() public {
        // 'stranger' nunca fue registrado en MockFactory como evento válido
        vm.prank(stranger);
        vm.expectRevert(RewardsVault.UnknownEvent.selector);
        vault.notifyRedeem(fan, 1);
    }

    function test_notifyRedeem_unknownCaller_doesNotPay() public {
        vm.prank(stranger);
        vm.expectRevert(RewardsVault.UnknownEvent.selector);
        vault.notifyRedeem(fan, 1);

        assertEq(vbk.balanceOf(fan), 0);
    }

    function test_notifyRedeem_revokedEvent_reverts() public {
        // Un evento que estaba registrado y luego se desregistra
        factory.setEvent(eventNFT, false);

        vm.prank(eventNFT);
        vm.expectRevert(RewardsVault.UnknownEvent.selector);
        vault.notifyRedeem(fan, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    // notifyRedeem — validaciones
    // ══════════════════════════════════════════════════════════════════════

    function test_notifyRedeem_zeroFan_reverts() public {
        vm.prank(eventNFT);
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        vault.notifyRedeem(address(0), 1);
    }

    function test_notifyRedeem_alreadyPaid_reverts() public {
        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);

        vm.prank(eventNFT);
        vm.expectRevert(RewardsVault.AlreadyPaid.selector);
        vault.notifyRedeem(fan, 1);
    }

    function test_notifyRedeem_differentTokenIds_bothPay() public {
        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);
        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 2);

        assertEq(vbk.balanceOf(fan), 2 * REWARD_USDC * router.ratio());
        assertTrue(vault.rewardPaid(eventNFT, 1));
        assertTrue(vault.rewardPaid(eventNFT, 2));
    }

    function test_notifyRedeem_sameTokenId_differentEvents_bothPay() public {
        address eventNFT2 = makeAddr("eventNFT2");
        factory.setEvent(eventNFT2, true);

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);
        vm.prank(eventNFT2);
        vault.notifyRedeem(fan, 1); // mismo tokenId, otro evento: no choca

        assertTrue(vault.rewardPaid(eventNFT, 1));
        assertTrue(vault.rewardPaid(eventNFT2, 1));
    }

    // ══════════════════════════════════════════════════════════════════════
    // notifyRedeem — fallos de fondos: NO revierte, emite evento
    // ══════════════════════════════════════════════════════════════════════

    function test_notifyRedeem_insufficientAllowance_doesNotRevert() public {
        // Treasury retira el allowance
        vm.prank(treasury);
        vbk.approve(address(vault), 0);

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1); // no revierte

        assertEq(vbk.balanceOf(fan), 0);
        assertFalse(vault.rewardPaid(eventNFT, 1)); // no se marca como pagado
    }

    function test_notifyRedeem_insufficientAllowance_emitsFailure() public {
        vm.prank(treasury);
        vbk.approve(address(vault), 0);

        vm.expectEmit(true, true, true, false, address(vault));
        emit RewardsVault.RewardPaymentFailed(eventNFT, 1, fan, "");

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);
    }

    function test_notifyRedeem_insufficientBalance_doesNotRevert() public {
        // Treasury con allowance pero sin balance real
        address poorTreasury = makeAddr("poorTreasury");
        vm.prank(admin);
        vault.setTreasury(poorTreasury);
        vm.prank(poorTreasury);
        vbk.approve(address(vault), type(uint256).max);
        // poorTreasury nunca recibió mint, balance = 0

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1); // no revierte

        assertEq(vbk.balanceOf(fan), 0);
        assertFalse(vault.rewardPaid(eventNFT, 1));
    }

    function test_notifyRedeem_transferFromReturnsFalse_doesNotRevert() public {
        vbk.setReturnFalse(true);

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1); // no revierte

        assertFalse(vault.rewardPaid(eventNFT, 1));
    }

    function test_notifyRedeem_transferFromRevertsWithMessage_doesNotRevert() public {
        vbk.setRevertWithMessage(true);

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1); // no revierte, pese a que VBK.transferFrom revierte

        assertFalse(vault.rewardPaid(eventNFT, 1));
        assertEq(vbk.balanceOf(fan), 0);
    }

    function test_notifyRedeem_routerNoLiquidity_doesNotRevert() public {
        router.setShouldRevert(true);

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1); // no revierte, pese a que el router revierte

        assertFalse(vault.rewardPaid(eventNFT, 1));
        assertEq(vbk.balanceOf(fan), 0);
    }

    function test_notifyRedeem_routerNoLiquidity_emitsFailure() public {
        router.setShouldRevert(true);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsVault.RewardPaymentFailed(eventNFT, 1, fan, "router quote failed");

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);
    }

    function test_notifyRedeem_canRetryAfterFailedPayment() public {
        // Primer intento falla por falta de allowance
        vm.prank(treasury);
        vbk.approve(address(vault), 0);
        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);
        assertFalse(vault.rewardPaid(eventNFT, 1));

        // Se restablece el allowance, se reintenta (no hay rewardPaid que lo bloquee)
        vm.prank(treasury);
        vbk.approve(address(vault), type(uint256).max);
        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);

        assertTrue(vault.rewardPaid(eventNFT, 1));
        assertEq(vbk.balanceOf(fan), REWARD_USDC * router.ratio());
    }

    // ══════════════════════════════════════════════════════════════════════
    // Pausable
    // ══════════════════════════════════════════════════════════════════════

    function test_notifyRedeem_whenPaused_reverts() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(eventNFT);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.notifyRedeem(fan, 1);
    }

    function test_unpause_resumesNotifyRedeem() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(admin);
        vault.unpause();

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1); // no revierte
        assertTrue(vault.rewardPaid(eventNFT, 1));
    }

    function test_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.unpause();
    }

    // ══════════════════════════════════════════════════════════════════════
    // Admin setters
    // ══════════════════════════════════════════════════════════════════════

    function test_setRewardUSDC_success() public {
        vm.prank(admin);
        vault.setRewardUSDC(0.25e6);
        assertEq(vault.rewardUSDC(), 0.25e6);
    }

    function test_setRewardUSDC_affectsNextPayment() public {
        vm.prank(admin);
        vault.setRewardUSDC(0.50e6);

        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);

        assertEq(vbk.balanceOf(fan), 0.50e6 * router.ratio());
    }

    function test_setRewardUSDC_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setRewardUSDC(1e6);
    }

    function test_setTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        vault.setTreasury(newTreasury);
        assertEq(vault.treasury(), newTreasury);
    }

    function test_setTreasury_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
    }

    function test_setTreasury_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setTreasury(makeAddr("x"));
    }

    function test_setRouter_success() public {
        MockRouter newRouter = new MockRouter();
        vm.prank(admin);
        vault.setRouter(address(newRouter));
        assertEq(address(vault.router()), address(newRouter));
    }

    function test_setRouter_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        vault.setRouter(address(0));
    }

    function test_setRouter_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setRouter(address(router));
    }

    function test_setFactory_success() public {
        MockFactory newFactory = new MockFactory();
        vm.prank(admin);
        vault.setFactory(address(newFactory));
        assertEq(address(vault.factory()), address(newFactory));
    }

    function test_setFactory_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(RewardsVault.ZeroAddress.selector);
        vault.setFactory(address(0));
    }

    function test_setFactory_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setFactory(address(factory));
    }

    function test_setFactory_changesAuthorizedCallers() public {
        // Con la factory vieja, 'eventNFT' es válido
        vm.prank(eventNFT);
        vault.notifyRedeem(fan, 1);

        // Factory nueva, sin 'eventNFT' registrado
        MockFactory newFactory = new MockFactory();
        vm.prank(admin);
        vault.setFactory(address(newFactory));

        vm.prank(eventNFT);
        vm.expectRevert(RewardsVault.UnknownEvent.selector);
        vault.notifyRedeem(fan, 2);
    }

    // ══════════════════════════════════════════════════════════════════════
    // quoteReward (view)
    // ══════════════════════════════════════════════════════════════════════

    function test_quoteReward_matchesRouterRatio() public view {
        assertEq(vault.quoteReward(), REWARD_USDC * router.ratio());
    }

    function test_quoteReward_reflectsRewardUSDCChange() public {
        vm.prank(admin);
        vault.setRewardUSDC(1e6);
        assertEq(vault.quoteReward(), 1e6 * router.ratio());
    }

    function test_quoteReward_reflectsRatioChange() public {
        router.setRatio(50);
        assertEq(vault.quoteReward(), REWARD_USDC * 50);
    }

    function test_quoteReward_doesNotConsumeAllowance() public {
        uint256 allowanceBefore = vbk.allowance(treasury, address(vault));
        vault.quoteReward();
        assertEq(vbk.allowance(treasury, address(vault)), allowanceBefore);
    }
}
