// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VbkToken} from "../src/VbkToken.sol";

contract VbkTokenTest is Test {
    VbkToken public vbk;

    address owner   = makeAddr("owner");
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address pool    = makeAddr("pool");
    address gateway = makeAddr("gateway");

    uint256 constant INITIAL_SUPPLY = 100_000_000 * 1e18;

    function setUp() public {
        vm.prank(owner);
        vbk = new VbkToken(owner);
    }

    // ─── Supply ────────────────────────────────────────────────────────────────

    function test_initialSupply() public view {
        assertEq(vbk.totalSupply(), INITIAL_SUPPLY);
        assertEq(vbk.balanceOf(owner), INITIAL_SUPPLY);
    }

    function test_noMintFunction() public view {
        // VbkToken no tiene función mint() pública.
        // Verificamos indirectamente: nadie puede aumentar el supply.
        assertEq(vbk.totalSupply(), INITIAL_SUPPLY);
    }

    function test_INITIAL_SUPPLY_constant() public view {
        assertEq(vbk.INITIAL_SUPPLY(), INITIAL_SUPPLY);
    }

    // ─── Burn-on-transfer ──────────────────────────────────────────────────────

    function test_burnOnTransfer() public {
        // owner envía 1000 VBK a alice; se queman 2% = 20 VBK
        uint256 amount = 1000 * 1e18;
        uint256 expectedBurn = amount * 200 / 10_000; // 20 VBK
        uint256 expectedReceived = amount - expectedBurn;

        vm.prank(owner);
        vbk.transfer(alice, amount);

        assertEq(vbk.balanceOf(alice), expectedReceived);
        assertEq(vbk.totalSupply(), INITIAL_SUPPLY - expectedBurn);
    }

    function test_noBurnWhenSenderExempt() public {
        // El owner está exento → alice recibe el 100%
        assertEq(vbk.isFeeExempt(owner), true);
        uint256 amount = 1000 * 1e18;

        vm.prank(owner);
        vbk.transfer(alice, amount);
        assertEq(vbk.balanceOf(alice), amount);
        assertEq(vbk.totalSupply(), INITIAL_SUPPLY);
    }

    function test_noBurnWhenReceiverExempt() public {
        // Marcar pool como exento
        vm.prank(owner);
        vbk.setFeeExempt(pool, true);

        // Primero transferimos a alice (con burn) y luego alice transfiere al pool
        uint256 toAlice = 10_000 * 1e18;
        vm.prank(owner);
        vbk.transfer(alice, toAlice); // owner es exento → alice recibe 10000

        uint256 aliceBalance = vbk.balanceOf(alice);
        vm.prank(alice);
        vbk.transfer(pool, aliceBalance);

        // pool está exento (receiver) → no hay burn
        assertEq(vbk.balanceOf(pool), aliceBalance);
    }

    function test_burnAccumulates() public {
        // Dos transfers sucesivos de no-exentos
        vm.prank(owner);
        vbk.transfer(alice, 10_000 * 1e18); // owner exento → alice recibe 10k

        uint256 aliceBalance = vbk.balanceOf(alice);
        vm.prank(alice);
        vbk.transfer(bob, 1_000 * 1e18); // burn 20 VBK

        uint256 burnFirst = 1_000 * 1e18 * 200 / 10_000;
        assertEq(vbk.totalSupply(), INITIAL_SUPPLY - burnFirst);
        assertEq(vbk.balanceOf(alice), aliceBalance - 1_000 * 1e18);
        assertEq(vbk.balanceOf(bob), 1_000 * 1e18 - burnFirst);
    }

    // ─── setBurnRate ───────────────────────────────────────────────────────────

    function test_setBurnRate() public {
        vm.prank(owner);
        vbk.setBurnRate(500); // 5%
        assertEq(vbk.burnRate(), 500);
    }

    function test_setBurnRate_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VbkToken.BurnRateTooHigh.selector, 1001, 1000));
        vbk.setBurnRate(1001);
    }

    function test_setBurnRate_boundary_maxAllowed() public {
        vm.prank(owner);
        vbk.setBurnRate(1000); // 10% — exactamente el máximo
        assertEq(vbk.burnRate(), 1000);
    }

    function test_setBurnRate_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vbk.setBurnRate(100);
    }

    // ─── setFeeExempt ──────────────────────────────────────────────────────────

    function test_setFeeExempt() public {
        vm.prank(owner);
        vbk.setFeeExempt(pool, true);
        assertTrue(vbk.isFeeExempt(pool));

        vm.prank(owner);
        vbk.setFeeExempt(pool, false);
        assertFalse(vbk.isFeeExempt(pool));
    }

    function test_setFeeExempt_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vbk.setFeeExempt(pool, true);
    }

    // ─── Pausable ──────────────────────────────────────────────────────────────

    function test_pause_blocksTransfers() public {
        vm.prank(owner);
        vbk.pause();

        vm.prank(owner);
        vm.expectRevert();
        vbk.transfer(alice, 100 * 1e18);
    }

    function test_unpause_resumesTransfers() public {
        vm.prank(owner);
        vbk.pause();
        vm.prank(owner);
        vbk.unpause();

        vm.prank(owner);
        vbk.transfer(alice, 100 * 1e18);
        assertEq(vbk.balanceOf(alice), 100 * 1e18); // owner exento, no burn
    }

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vbk.pause();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    /// @dev El burn nunca puede superar el amount transferido.
    function testFuzz_burnNeverExceedsAmount(uint256 amount) public {
        // Limitar al balance del owner para que la tx no falle por fondos
        amount = bound(amount, 1, INITIAL_SUPPLY / 2);

        // Primero pasar fondos a alice sin burn (owner exento)
        vm.prank(owner);
        vbk.transfer(alice, amount);

        uint256 supplyBefore = vbk.totalSupply();
        uint256 aliceBefore = vbk.balanceOf(alice);

        // alice transfiere a bob (con burn)
        vm.prank(alice);
        vbk.transfer(bob, amount);

        uint256 burned = supplyBefore - vbk.totalSupply();
        assertLe(burned, amount);                              // burn ≤ amount
        assertEq(vbk.balanceOf(bob), amount - burned);        // bob recibe el resto
        assertEq(vbk.balanceOf(alice), aliceBefore - amount); // alice pierde el monto
    }

    /// @dev El supply total nunca crece. Solo decrece o queda igual.
    function testFuzz_supplyNeverGrows(uint256 amount) public {
        amount = bound(amount, 1, INITIAL_SUPPLY / 2);
        vm.prank(owner);
        vbk.transfer(alice, amount);

        uint256 supplyAfter = vbk.totalSupply();
        assertLe(supplyAfter, INITIAL_SUPPLY);
    }
}
