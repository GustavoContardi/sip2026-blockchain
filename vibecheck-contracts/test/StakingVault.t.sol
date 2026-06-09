// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {MockVBK} from "./mocks/MockVBK.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract StakingVaultTest is Test {
    MockVBK internal vbk;
    StakingVault internal vault;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant ONE = 1e18;

    // Re-declaración de eventos para expectEmit.
    event Locked(
        address indexed user,
        uint256 indexed lockId,
        uint256 amount,
        uint32 termDays,
        uint64 unlockTime
    );
    event Withdrawn(address indexed user, uint256 indexed lockId, uint256 amount);

    function setUp() public {
        vbk = new MockVBK();
        vault = new StakingVault(address(vbk), owner);

        // El vault exento de burn (lo que en producción se hace con setFeeExempt).
        vbk.setFeeExempt(address(vault), true);

        // Fondos y approves.
        vbk.mint(alice, 1_000 * ONE);
        vbk.mint(bob, 1_000 * ONE);
        vm.prank(alice);
        vbk.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vbk.approve(address(vault), type(uint256).max);
    }

    // --------------------------------------------------------------- stake

    function test_stake_createsLock_andCustodiesVBK() public {
        uint256 amount = 100 * ONE;

        vm.prank(alice);
        uint256 lockId = vault.stake(amount, 30);

        assertEq(lockId, 0);
        assertEq(vault.totalLocked(alice), amount);
        assertEq(vbk.balanceOf(address(vault)), amount);
        assertEq(vbk.balanceOf(alice), 900 * ONE);

        StakingVault.Lock memory l = vault.getLock(alice, 0);
        assertEq(l.amount, amount);
        assertEq(l.termDays, 30);
        assertEq(l.unlockTime, uint64(block.timestamp + 30 days));
        assertFalse(l.withdrawn);
    }

    function test_stake_emitsLocked() public {
        uint256 amount = 50 * ONE;
        uint64 expectedUnlock = uint64(block.timestamp + 60 days);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Locked(alice, 0, amount, 60, expectedUnlock);

        vm.prank(alice);
        vault.stake(amount, 60);
    }

    function test_stake_creditsActualReceived_whenNotExempt() public {
        // Quitamos la exención y activamos burn 2%: el vault debe acreditar lo recibido.
        vbk.setFeeExempt(address(vault), false);
        vbk.setBurnRate(200); // 2%

        uint256 amount = 100 * ONE;
        uint256 expectedReceived = 98 * ONE;

        vm.prank(alice);
        vault.stake(amount, 90);

        StakingVault.Lock memory l = vault.getLock(alice, 0);
        assertEq(l.amount, expectedReceived, "acredita el neto recibido");
        assertEq(vault.totalLocked(alice), expectedReceived);
        assertEq(vbk.balanceOf(address(vault)), expectedReceived, "vault solvente");
    }

    function test_stake_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.stake(0, 30);
    }

    function test_stake_revert_termNotAllowed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.TermNotAllowed.selector, uint32(45)));
        vault.stake(10 * ONE, 45);
    }

    function test_stake_revert_whenPaused() public {
        vault.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.stake(10 * ONE, 30);
    }

    // ------------------------------------------------------------ withdraw

    function test_withdraw_afterTerm_returnsPrincipal() public {
        uint256 amount = 100 * ONE;
        vm.prank(alice);
        vault.stake(amount, 30);

        vm.warp(block.timestamp + 30 days);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Withdrawn(alice, 0, amount);

        vm.prank(alice);
        vault.withdraw(0);

        assertEq(vault.totalLocked(alice), 0);
        assertEq(vbk.balanceOf(alice), 1_000 * ONE, "recupera el principal completo");
        assertEq(vbk.balanceOf(address(vault)), 0);

        StakingVault.Lock memory l = vault.getLock(alice, 0);
        assertTrue(l.withdrawn);
    }

    function test_withdraw_revert_beforeTerm() public {
        vm.prank(alice);
        vault.stake(100 * ONE, 30);

        uint64 unlock = uint64(block.timestamp + 30 days);
        vm.warp(block.timestamp + 29 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, unlock));
        vault.withdraw(0);
    }

    function test_withdraw_revert_alreadyWithdrawn() public {
        vm.prank(alice);
        vault.stake(100 * ONE, 30);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vault.withdraw(0);

        vm.prank(alice);
        vm.expectRevert(StakingVault.AlreadyWithdrawn.selector);
        vault.withdraw(0);
    }

    function test_withdraw_revert_invalidLockId() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.InvalidLockId.selector);
        vault.withdraw(0);
    }

    // ------------------------------------------------ concurrent locks

    function test_multipleConcurrentLocks() public {
        vm.startPrank(alice);
        vault.stake(100 * ONE, 30);
        vault.stake(200 * ONE, 90);
        vm.stopPrank();

        assertEq(vault.getLockCount(alice), 2);
        assertEq(vault.totalLocked(alice), 300 * ONE);

        // A los 30 días: retira el primero, el segundo sigue bloqueado.
        vm.warp(block.timestamp + 30 days);

        assertTrue(vault.isWithdrawable(alice, 0));
        assertFalse(vault.isWithdrawable(alice, 1));

        vm.prank(alice);
        vault.withdraw(0);
        assertEq(vault.totalLocked(alice), 200 * ONE);

        // Capturar unlockTime ANTES del prank. Si getLock se llama dentro del
        // argumento de expectRevert, consume el prank y withdraw(1) correría como
        // el contrato de test (sin locks) -> InvalidLockId en vez de StillLocked.
        uint64 lock1Unlock = vault.getLock(alice, 1).unlockTime;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, lock1Unlock));
        vault.withdraw(1);
    }

    // --------------------------------------------------------- views

    function test_activeLockedByMinTerm_filtersByTerm() public {
        vm.startPrank(alice);
        vault.stake(100 * ONE, 30);
        vault.stake(200 * ONE, 90);
        vm.stopPrank();

        assertEq(vault.activeLockedByMinTerm(alice, 30), 300 * ONE);
        assertEq(vault.activeLockedByMinTerm(alice, 60), 200 * ONE);
        assertEq(vault.activeLockedByMinTerm(alice, 90), 200 * ONE);
        assertEq(vault.activeLockedByMinTerm(alice, 91), 0);
    }

    function test_activeLockedByMinTerm_dropsWithdrawn() public {
        vm.startPrank(alice);
        vault.stake(100 * ONE, 90);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        vm.prank(alice);
        vault.withdraw(0);

        assertEq(vault.activeLockedByMinTerm(alice, 30), 0);
    }

    function test_getLocks_returnsArray() public {
        vm.startPrank(alice);
        vault.stake(10 * ONE, 30);
        vault.stake(20 * ONE, 60);
        vm.stopPrank();

        StakingVault.Lock[] memory locks = vault.getLocks(alice);
        assertEq(locks.length, 2);
        assertEq(locks[0].termDays, 30);
        assertEq(locks[1].termDays, 60);
    }

    function test_isWithdrawable_falseForBadId() public view {
        assertFalse(vault.isWithdrawable(alice, 99));
    }

    // --------------------------------------------------------- admin

    function test_setTerm_ownerCanAddNewTerm() public {
        vault.setTerm(180, true);
        assertTrue(vault.allowedTermDays(180));

        vm.prank(alice);
        vault.stake(10 * ONE, 180);
        assertEq(vault.getLock(alice, 0).termDays, 180);
    }

    function test_setTerm_ownerCanDisableTerm() public {
        vault.setTerm(30, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.TermNotAllowed.selector, uint32(30)));
        vault.stake(10 * ONE, 30);
    }

    function test_setTerm_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setTerm(180, true);
    }

    function test_pause_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.pause();
    }

    function test_pauseUnpause_allowsStakeAgain() public {
        vault.pause();
        vault.unpause();
        vm.prank(alice);
        vault.stake(10 * ONE, 30); // no revierte
        assertEq(vault.getLockCount(alice), 1);
    }

    function test_withdraw_notBlockedByPause() public {
        vm.prank(alice);
        vault.stake(100 * ONE, 30);
        vm.warp(block.timestamp + 30 days);

        vault.pause(); // pausa stakes, no retiros
        vm.prank(alice);
        vault.withdraw(0);
        assertEq(vbk.balanceOf(alice), 1_000 * ONE);
    }
}
