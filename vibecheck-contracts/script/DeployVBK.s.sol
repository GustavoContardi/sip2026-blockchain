// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VbkToken} from "../src/VbkToken.sol";

/**
 * @notice Deploya VbkToken con supply fijo 100M.
 *
 * Variables de entorno requeridas:
 *   TREASURY   — wallet que recibe los 100M VBK y es owner del contrato
 *
 * Uso:
 *   forge script script/DeployVBK.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * Post-deploy:
 *   1. Crear pool VBK/USDC en Uniswap V2 (addLiquidity)
 *   2. vbk.setFeeExempt(poolAddress, true)
 *   3. vbk.setFeeExempt(offeringNFTAddress, true)
 *   4. vbk.setFeeExempt(nftMarketplaceAddress, true)
 */
contract DeployVBK is Script {
    function run() external returns (VbkToken vbk) {
        address owner = vm.envAddress("TREASURY");

        vm.startBroadcast();
        vbk = new VbkToken(owner);
        vm.stopBroadcast();

        console.log("=== VbkToken deployed ===");
        console.log("Address:        ", address(vbk));
        console.log("Owner:          ", owner);
        console.log("Total supply:   100,000,000 VBK");
        console.log("Burn rate:      2.00%");
        console.log("Mint function:  NONE (supply is fixed)");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Create Uniswap V2 pool VBK/USDC");
        console.log("  2. call setFeeExempt(pool, true)");
        console.log("  3. call setFeeExempt(offeringNFT, true) after deploy");
        console.log("  4. call setFeeExempt(nftMarketplace, true) after deploy");
    }
}
