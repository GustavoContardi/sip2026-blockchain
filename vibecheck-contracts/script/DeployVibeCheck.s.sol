// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {OfferingNFT} from "../src/OfferingNFT.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";

/**
 * @notice Deploya la infraestructura completa de VibeCheck:
 *         EventFactory + OfferingNFT + NFTMarketplace
 *
 * Variables de entorno requeridas:
 *   TREASURY          — wallet que recibe fees de plataforma y es owner
 *   USDC_SEPOLIA      — address del USDC en Sepolia
 *   VBK_ADDR          — address del VbkToken ya deployado
 *   UNISWAP_V2_ROUTER — address del Router V2 en Sepolia
 *
 * Orden de deploys:
 *   1. Deploy EventFactory
 *   2. Deploy OfferingNFT (lee usdc/vbk/router del factory)
 *   3. Deploy NFTMarketplace (lee usdc del factory)
 *   4. factory.setOffering(offering)
 *   5. factory.setMarketplace(marketplace)
 *
 * Uso:
 *   forge script script/DeployVibeCheck.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * Post-deploy (manual, con el token owner):
 *   vbk.setFeeExempt(offering, true)
 *   vbk.setFeeExempt(marketplace, true)
 *   factory.grantOrganizer(0xProductoraAddress)
 */
contract DeployVibeCheck is Script {
    function run() external returns (
        EventFactory   factory,
        OfferingNFT    offering,
        NFTMarketplace marketplace
    ) {
        address treasury = vm.envAddress("TREASURY");
        address usdc     = vm.envAddress("USDC_SEPOLIA");
        address vbk      = vm.envAddress("VBK_ADDR");
        address router   = vm.envAddress("UNISWAP_V2_ROUTER");

        vm.startBroadcast();

        // 1. EventFactory
        factory = new EventFactory(treasury, usdc, vbk, router, treasury);

        // 2. OfferingNFT — lee usdc/vbk/router del factory automáticamente
        offering = new OfferingNFT(treasury, factory, treasury);

        // 3. NFTMarketplace
        marketplace = new NFTMarketplace(treasury, factory, treasury);

        // 4. Bootstrap one-shot (sin esto nadie puede lanzar eventos)
        factory.setOffering(address(offering));
        factory.setMarketplace(address(marketplace));

        vm.stopBroadcast();

        console.log("=== VibeCheck deployed ===");
        console.log("EventFactory:    ", address(factory));
        console.log("OfferingNFT:     ", address(offering));
        console.log("NFTMarketplace:  ", address(marketplace));
        console.log("");
        console.log("Config:");
        console.log("  USDC:    ", usdc);
        console.log("  VBK:     ", vbk);
        console.log("  Router:  ", router);
        console.log("  Treasury:", treasury);
        console.log("");
        console.log("Fees:");
        console.log("  Venta primaria USDC:  5%");
        console.log("  Venta primaria VBK:   2%");
        console.log("  Reventa fee:         10%");
        console.log("");
        console.log("Next steps (manual):");
        console.log("  vbk.setFeeExempt(offering, true)");
        console.log("  vbk.setFeeExempt(marketplace, true)");
        console.log("  factory.grantOrganizer(0xProductoraAddress)");
    }
}
