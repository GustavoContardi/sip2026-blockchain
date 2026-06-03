// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {OfferingNFT} from "../src/OfferingNFT.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";
import {VbkToken} from "../src/VbkToken.sol";

/**
 * @notice Deploya la infraestructura completa de VibeCheck y la deja 100% operativa:
 *         EventFactory + OfferingNFT + NFTMarketplace, con exenciones de burn VBK
 *         y refundSigner ya configurados. Sin pasos manuales post-deploy.
 *
 * REQUISITO: la cuenta que corre el broadcast debe ser la owner del VbkToken
 *            y el admin/owner del resto (es treasury en este script). Si no, los
 *            setFeeExempt / setRefundSigner / setOffering revierten.
 *
 * Variables de entorno requeridas:
 *   TREASURY          — wallet que recibe fees, es owner de los contratos y admin del factory
 *   USDC_SEPOLIA      — address del USDC en Sepolia
 *   VBK_ADDR          — address del VbkToken ya deployado (su owner debe ser TREASURY)
 *   UNISWAP_V2_ROUTER — address del Router V2 en Sepolia
 *   REFUND_SIGNER     — address pública del firmante de reembolsos voluntarios (clave en el backend)
 *
 * Uso:
 *   forge script script/DeployVibeCheck.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 */
contract DeployVibeCheck is Script {
    function run() external returns (
        EventFactory   factory,
        OfferingNFT    offering,
        NFTMarketplace marketplace
    ) {
        address treasury     = vm.envAddress("TREASURY");
        address usdc         = vm.envAddress("USDC_SEPOLIA");
        address vbk          = vm.envAddress("VBK_ADDR");
        address router       = vm.envAddress("UNISWAP_V2_ROUTER");
        address refundSigner = vm.envAddress("REFUND_SIGNER");

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

        // 5. Exenciones de burn VBK: sin esto, los pagos en VBK pierden 2% en cada
        //    transferencia interna y corrompen los montos del escrow.
        VbkToken(vbk).setFeeExempt(address(offering), true);
        VbkToken(vbk).setFeeExempt(address(marketplace), true);

        // 6. Firmante de reembolsos voluntarios. Sin esto, refundVoluntary revierte
        //    con RefundSignerNotSet.
        offering.setRefundSigner(refundSigner);

        vm.stopBroadcast();

        console.log("=== VibeCheck deployed ===");
        console.log("EventFactory:    ", address(factory));
        console.log("OfferingNFT:     ", address(offering));
        console.log("NFTMarketplace:  ", address(marketplace));
        console.log("");
        console.log("Config:");
        console.log("  USDC:        ", usdc);
        console.log("  VBK:         ", vbk);
        console.log("  Router:      ", router);
        console.log("  Treasury:    ", treasury);
        console.log("  RefundSigner:", refundSigner);
        console.log("");
        console.log("Fees:");
        console.log("  Venta primaria USDC:  5%");
        console.log("  Venta primaria VBK:   2%");
        console.log("  Reventa USDC:         7%");
        console.log("  Reventa VBK:          4%");
        console.log("");
        console.log("Estado: feeExempt(offering/marketplace) y refundSigner ya seteados.");
        console.log("Listo para launchEvent(...). No quedan pasos manuales.");
    }
}
