// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VibeCheckToken} from "../src/VibeCheckToken.sol";

contract DeployVBK is Script {
    function run() external returns (VibeCheckToken vbk) {
        address owner = vm.envAddress("TREASURY");

        vm.startBroadcast();
        vbk = new VibeCheckToken(owner);
        vm.stopBroadcast();

        console.log("VibeCheckToken (VBK) deployed at:", address(vbk));
        console.log("Owner:                           ", owner);
        console.log("Initial supply:                   10,000 VBK");
        console.log("Burn rate:                        2.00%");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Create Uniswap V2 pool with VBK/USDC");
        console.log("  2. Call setFeeExempt(poolAddress, true)");
        console.log("  3. Optionally setFeeExempt(gatewayAddress, true)");
    }
}
