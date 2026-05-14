// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VibeCheckToken} from "../src/VibeCheckToken.sol";

contract VibeCheckTokenTest is Test {
    VibeCheckToken internal vbk;
    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal pool = makeAddr("uniswap-pool");
    address internal gateway = makeAddr("payment-gateway");

    function setUp() public {
        vbk = new VibeCheckToken(owner);
    }

    // ------------------------------------------------------------
    // Constructor + supply inicial
    // ------------------------------------------------------------

    function test_InitialSupplyMintedToOwner() public view {
        assertEq(vbk.totalSupply(), 10_000 ether);
        assertEq(vbk.balanceOf(owner), 10_000 ether);
    }

    function test_NameAndSymbol() public view {
        assertEq(vbk.name(), "VibeCheckToken");
        assertEq(vbk.symbol(), "VBK");
        assertEq(vbk.decimals(), 18);
    }

    function test_OwnerIsDeployer() public view {
        assertEq(vbk.owner(), owner);
    }

    function test_OwnerIsExemptByDefault() public view {
        assertTrue(vbk.isFeeExempt(owner));
    }

    function test_InitialBurnRateIs2Percent() public view {
        assertEq(vbk.burnRate(), 200);
    }

    // ------------------------------------------------------------
    // Burn-on-transfer
    // ------------------------------------------------------------

    function test_TransferUserToUser_BurnsTwoPercent() public {
        vbk.transfer(alice, 1000 ether); // owner exento → no quema
        assertEq(vbk.balanceOf(alice), 1000 ether);

        vm.prank(alice);
        vbk.transfer(bob, 100 ether); // alice no exenta → quema 2%

        assertEq(vbk.balanceOf(bob), 98 ether);
        assertEq(vbk.balanceOf(alice), 900 ether);
        assertEq(vbk.totalSupply(), 10_000 ether - 2 ether);
    }

    function test_Mint_DoesNotBurn() public {
        uint256 supplyBefore = vbk.totalSupply();
        vbk.mint(alice, 500 ether);
        assertEq(vbk.balanceOf(alice), 500 ether);
        assertEq(vbk.totalSupply(), supplyBefore + 500 ether);
    }

    function test_OnlyOwnerCanMint() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        vbk.mint(alice, 1000 ether);
    }

    // ------------------------------------------------------------
    // Exenciones (Pool de Uniswap + Gateway)
    // ------------------------------------------------------------

    function test_PoolExempt_SwapDoesNotBurn() public {
        // Setup: alice tiene VBK, el pool simula Uniswap
        vbk.transfer(alice, 10_000 ether);
        vbk.setFeeExempt(pool, true);

        // Alice deposita en el pool (alice → pool): pool exento, no quema
        vm.prank(alice);
        vbk.transfer(pool, 1000 ether);
        assertEq(vbk.balanceOf(pool), 1000 ether);

        // Pool entrega a bob (pool → bob): pool exento, no quema
        vm.prank(pool);
        vbk.transfer(bob, 500 ether);
        assertEq(vbk.balanceOf(bob), 500 ether);
        assertEq(vbk.balanceOf(pool), 500 ether);

        // Cero quemado en todo el swap simulado
        assertEq(vbk.totalSupply(), 10_000 ether);
    }

    function test_GatewayExempt_NoBurn() public {
        vbk.setFeeExempt(gateway, true);
        vbk.transfer(alice, 1000 ether);

        // Gateway recibe del usuario: no quema
        vm.prank(alice);
        vbk.transfer(gateway, 500 ether);
        assertEq(vbk.balanceOf(gateway), 500 ether);
        assertEq(vbk.totalSupply(), 10_000 ether);
    }

    function test_RemoveExemption_BurnAppliesAgain() public {
        vbk.transfer(alice, 1000 ether);
        vbk.setFeeExempt(pool, true);

        // Sin burn (pool exento)
        vm.prank(alice);
        vbk.transfer(pool, 100 ether);
        assertEq(vbk.balanceOf(pool), 100 ether);

        // Removemos exención
        vbk.setFeeExempt(pool, false);

        // Ahora sí quema
        vm.prank(alice);
        vbk.transfer(pool, 100 ether);
        assertEq(vbk.balanceOf(pool), 198 ether); // 100 + (100 - 2)
    }

    // ------------------------------------------------------------
    // Admin: burnRate
    // ------------------------------------------------------------

    function test_SetBurnRate_UpdatesValue() public {
        vbk.setBurnRate(500); // 5%
        assertEq(vbk.burnRate(), 500);

        vbk.transfer(alice, 1000 ether);
        vm.prank(alice);
        vbk.transfer(bob, 100 ether);
        assertEq(vbk.balanceOf(bob), 95 ether);
    }

    function test_SetBurnRate_RevertsAboveMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                VibeCheckToken.BurnRateTooHigh.selector,
                uint16(1001),
                uint16(1000)
            )
        );
        vbk.setBurnRate(1001);
    }

    function test_SetBurnRateToZero_DisablesBurn() public {
        vbk.setBurnRate(0);
        vbk.transfer(alice, 1000 ether);

        vm.prank(alice);
        vbk.transfer(bob, 100 ether);
        assertEq(vbk.balanceOf(bob), 100 ether);
        assertEq(vbk.totalSupply(), 10_000 ether);
    }

    function test_NonOwner_CannotSetBurnRate() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        vbk.setBurnRate(500);
    }

    function test_NonOwner_CannotSetFeeExempt() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        vbk.setFeeExempt(bob, true);
    }

    // ------------------------------------------------------------
    // Pausable
    // ------------------------------------------------------------

    function test_Pause_BlocksTransfers() public {
        vbk.transfer(alice, 1000 ether);
        vbk.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vbk.transfer(bob, 100 ether);
    }

    function test_Pause_BlocksMint() public {
        vbk.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vbk.mint(alice, 100 ether);
    }

    function test_Unpause_ResumesTransfers() public {
        vbk.transfer(alice, 1000 ether);
        vbk.pause();
        vbk.unpause();

        vm.prank(alice);
        vbk.transfer(bob, 100 ether);
        assertEq(vbk.balanceOf(bob), 98 ether);
    }

    function test_NonOwner_CannotPause() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        vbk.pause();
    }

    function test_NonOwner_CannotUnpause() public {
        vbk.pause();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        vbk.unpause();
    }

    // ------------------------------------------------------------
    // Fuzz tests
    // ------------------------------------------------------------

    /// Cada transfer usuario→usuario quema exactamente 2% del amount.
    function testFuzz_BurnAmountAlwaysCorrect(uint256 amount) public {
        amount = bound(amount, 100, 10_000 ether);
        vbk.transfer(alice, amount);

        uint256 supplyBefore = vbk.totalSupply();
        uint256 expectedBurn = (amount * 200) / 10000;

        vm.prank(alice);
        vbk.transfer(bob, amount);

        assertEq(vbk.balanceOf(bob), amount - expectedBurn);
        assertEq(vbk.totalSupply(), supplyBefore - expectedBurn);
    }

    /// Cualquier burnRate válido produce el burn correcto.
    function testFuzz_AnyValidBurnRate(uint16 rate, uint256 amount) public {
        rate = uint16(bound(uint256(rate), 0, 1000));
        amount = bound(amount, 100, 1_000 ether);

        vbk.setBurnRate(rate);
        vbk.transfer(alice, amount);

        uint256 expectedBurn = (amount * rate) / 10000;
        uint256 supplyBefore = vbk.totalSupply();

        vm.prank(alice);
        vbk.transfer(bob, amount);

        assertEq(vbk.balanceOf(bob), amount - expectedBurn);
        assertEq(vbk.totalSupply(), supplyBefore - expectedBurn);
    }

    /// Cualquier address exentada nunca paga burn (en ningún sentido del transfer).
    function testFuzz_ExemptAddressNeverPaysBurn(address exempt, uint256 amount) public {
        vm.assume(exempt != address(0));
        vm.assume(exempt != owner);
        vm.assume(exempt != alice);
        amount = bound(amount, 100, 1_000 ether);

        vbk.transfer(alice, amount);
        vbk.setFeeExempt(exempt, true);

        uint256 supplyBefore = vbk.totalSupply();

        vm.prank(alice);
        vbk.transfer(exempt, amount);

        assertEq(vbk.balanceOf(exempt), amount);
        assertEq(vbk.totalSupply(), supplyBefore);
    }
}
