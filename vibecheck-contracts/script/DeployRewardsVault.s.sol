// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RewardsVault} from "../src/RewardsVault.sol";

/**
 * @notice Deploya RewardsVault. NO toca EventFactory, EventNFT, OfferingNFT
 *         ni NFTMarketplace existentes — son pasos manuales aparte (ver
 *         README de este script / mensaje de Claude).
 *
 * Variables de entorno requeridas:
 *   PRIVATE_KEY        - clave del admin (mismo admin que EventFactory)
 *   FACTORY_ADDRESS    - address ya deployada de EventFactory
 *   ROUTER_ADDRESS     - address del router Uniswap V2 (mismo que usa OfferingNFT)
 *   USDC_ADDRESS       - address del USDC en la red de deploy
 *   VBK_ADDRESS        - address de VbkToken ya deployado
 *   TREASURY_ADDRESS   - wallet que ya tiene VBK fondeado para pagar recompensas
 */
contract DeployRewardsVault is Script {
    function run() external returns (RewardsVault vault) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address admin      = vm.addr(deployerPk);

        address factory  = vm.envAddress("FACTORY_ADDRESS");
        address router   = vm.envAddress("ROUTER_ADDRESS");
        address usdc     = vm.envAddress("USDC_ADDRESS");
        address vbk      = vm.envAddress("VBK_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        console.log("Deployer / admin:", admin);
        console.log("Factory:", factory);
        console.log("Router:", router);
        console.log("USDC:", usdc);
        console.log("VBK:", vbk);
        console.log("Treasury:", treasury);

        vm.startBroadcast(deployerPk);

        vault = new RewardsVault(admin, factory, router, usdc, vbk, treasury);

        vm.stopBroadcast();

        console.log("RewardsVault deployed at:", address(vault));
        console.log("");
        console.log("PASOS MANUALES PENDIENTES (este script no los hace):");
        console.log("1. El treasury debe aprobar VBK a este vault:");
        console.log("   VbkToken.approve(", address(vault), ", <monto>)");
        console.log("2. Cada EventNFT existente debe activarlo (lo llama su organizer):");
        console.log("   EventNFT.setRewardsVault(", address(vault), ")");
    }
}
