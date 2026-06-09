// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";

/**
 * @dev Interfaz mínima del VbkToken para marcar la exención de burn.
 *      Ajustá la firma si tu VbkToken expone otro nombre/parámetros.
 */
interface IVbkFeeExempt {
    function setFeeExempt(address account, bool exempt) external;
}

/**
 * @title DeployStakingVault
 * @notice Deploy ADITIVO: no toca los contratos ya desplegados. Apunta al
 *         VbkToken existente, deploya StakingVault y lo marca fee-exempt.
 *
 * Requisitos de entorno:
 *   PRIVATE_KEY      -> clave que broadcastea, con o sin prefijo "0x".
 *                       DEBE poder llamar setFeeExempt en el VbkToken.
 *   VBK_TOKEN        -> address del VbkToken ya desplegado en Sepolia.
 *   VAULT_OWNER      -> (opcional) owner del StakingVault. Default: el deployer.
 *
 * Uso:
 *   forge script script/DeployStakingVault.s.sol:DeployStakingVault \
 *     --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
 */
contract DeployStakingVault is Script {
    function run() external {
        // Acepta la clave con o sin prefijo "0x".
        string memory pkRaw = vm.envString("PRIVATE_KEY");
        bytes memory pkBytes = bytes(pkRaw);
        bool hasPrefix = pkBytes.length >= 2 && pkBytes[0] == "0" && pkBytes[1] == "x";
        uint256 pk = vm.parseUint(hasPrefix ? pkRaw : string(abi.encodePacked("0x", pkRaw)));

        address deployer = vm.addr(pk);
        address vbk = vm.envAddress("VBK_TOKEN");
        address vaultOwner = vm.envOr("VAULT_OWNER", deployer);

        require(vbk != address(0), "VBK_TOKEN=0");

        vm.startBroadcast(pk);

        StakingVault vault = new StakingVault(vbk, vaultOwner);

        // Marca el vault exento del burn. El broadcaster (deployer) debe ser
        // el owner del VbkToken o esta llamada revierte.
        IVbkFeeExempt(vbk).setFeeExempt(address(vault), true);

        vm.stopBroadcast();

        console2.log("=== StakingVault deploy ===");
        console2.log("StakingVault:", address(vault));
        console2.log("VbkToken:    ", vbk);
        console2.log("Vault owner: ", vaultOwner);
        console2.log("Deployer:    ", deployer);
        console2.log("Terminos sembrados: 30/60/90 dias");
        console2.log("Fee-exempt aplicado al vault: true");
    }
}
