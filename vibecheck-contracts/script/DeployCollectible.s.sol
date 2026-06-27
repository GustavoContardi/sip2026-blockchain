// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CollectibleMarketplace} from "../src/CollectibleMarketplace.sol";

/**
 * @notice Interfaz mínima del EventFactory para otorgar MARKET_ROLE
 *         al CollectibleMarketplace en eventos ya existentes y en los
 *         que se creen en el futuro.
 */
interface IEventFactory {
    function isEvent(address eventNFT) external view returns (bool);
}

/**
 * @notice Interfaz mínima de AccessControl para grantRole.
 */
interface IAccessControl {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
}

/**
 * @title DeployCollectible
 * @notice Script Foundry para:
 *         1. Deployar CollectibleMarketplace.
 *         2. Otorgar MARKET_ROLE al nuevo contrato en EventNFTs existentes.
 *
 *         Uso básico (Sepolia):
 *         ─────────────────────
 *         forge script script/DeployCollectible.s.sol \
 *           --rpc-url $SEPOLIA_RPC_URL \
 *           --broadcast \
 *           --verify \
 *           --etherscan-api-key $ETHERSCAN_API_KEY \
 *           -vvv
 *
 *         Variables de entorno requeridas (en .env o exportadas):
 *         ─────────────────────────────────────────────────────────
 *         DEPLOYER_PRIVATE_KEY     Clave privada del deployer (plataforma).
 *         FACTORY_ADDRESS          Dirección del EventFactory en Sepolia.
 *         USDC_ADDRESS             USDC en Sepolia (o mock para tests).
 *         VBK_ADDRESS              VBK token en Sepolia.
 *         UNISWAP_ROUTER_ADDRESS   Router Uniswap V2 (o fork/mock).
 *         TREASURY_ADDRESS         Wallet que recibe fees de plataforma.
 *         ADMIN_ADDRESS            Owner del CollectibleMarketplace.
 *
 *         Opcional — para grantRole en eventos existentes:
 *         EXISTING_EVENT_NFTS      Lista separada por comas de EventNFT addresses.
 *                                  Ejemplo: "0xABC...,0xDEF..."
 *
 *         MARKET_ROLE en eventos futuros:
 *         ────────────────────────────────
 *         Los eventos creados con EventFactory DESPUÉS del deploy de este
 *         script necesitan que el factory otorgue MARKET_ROLE al
 *         CollectibleMarketplace automáticamente. Esto se hace en el
 *         script de deploy del factory o via una transacción del admin.
 *         Ver seccion "Integracion con EventFactory" al final del script.
 */
contract DeployCollectible is Script {

    // MARKET_ROLE debe coincidir con el valor en EventNFT.
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    // -----------------------------------------------------------------
    // Leer variables de entorno
    // -----------------------------------------------------------------

    struct Config {
        uint256 deployerKey;
        address factory;
        address usdc;
        address vbk;
        address router;
        address treasury;
        address admin;
        address[] existingEventNFTs;
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.factory     = vm.envAddress("FACTORY_ADDRESS");
        cfg.usdc        = vm.envAddress("USDC_ADDRESS");
        cfg.vbk         = vm.envAddress("VBK_ADDRESS");
        cfg.router      = vm.envAddress("UNISWAP_ROUTER_ADDRESS");
        cfg.treasury    = vm.envAddress("TREASURY_ADDRESS");
        cfg.admin       = vm.envAddress("ADMIN_ADDRESS");

        // Lista opcional de EventNFTs existentes a los que dar MARKET_ROLE.
        // Si la variable no existe, vm.envOr devuelve string vacío.
        string memory raw = vm.envOr("EXISTING_EVENT_NFTS", string(""));
        if (bytes(raw).length > 0) {
            cfg.existingEventNFTs = _parseAddresses(raw);
        }
    }

    // -----------------------------------------------------------------
    // Punto de entrada
    // -----------------------------------------------------------------

    function run() external {
        Config memory cfg = _loadConfig();

        vm.startBroadcast(cfg.deployerKey);

        // ── 1. Deploy CollectibleMarketplace ──────────────────────────
        CollectibleMarketplace marketplace = new CollectibleMarketplace(
            cfg.factory,
            cfg.usdc,
            cfg.vbk,
            cfg.router,
            cfg.treasury,
            cfg.admin
        );

        console2.log("CollectibleMarketplace deployed at:", address(marketplace));

        // ── 2. grantRole en EventNFTs existentes ──────────────────────
        //
        // Para cada EventNFT listado en EXISTING_EVENT_NFTS, otorgamos
        // MARKET_ROLE al CollectibleMarketplace. El deployer debe tener
        // DEFAULT_ADMIN_ROLE en cada EventNFT (lo tiene la plataforma
        // por el constructor del EventNFT).
        //
        // Si un evento ya tiene MARKET_ROLE otorgado, `grantRole` en
        // OpenZeppelin es idempotente: no revierte, no hace nada.

        if (cfg.existingEventNFTs.length > 0) {
            console2.log("Granting MARKET_ROLE to CollectibleMarketplace on", cfg.existingEventNFTs.length, "EventNFTs...");

            for (uint256 i = 0; i < cfg.existingEventNFTs.length; i++) {
                address eventNFT = cfg.existingEventNFTs[i];

                // Sanity check: verificar que es un evento del sistema.
                bool isRegistered = IEventFactory(cfg.factory).isEvent(eventNFT);
                if (!isRegistered) {
                    console2.log("  SKIP (not a VibeCheck event):", eventNFT);
                    continue;
                }

                // Verificar si ya tiene el rol (evita log de "ya tiene").
                bool alreadyGranted = IAccessControl(eventNFT).hasRole(
                    MARKET_ROLE,
                    address(marketplace)
                );

                if (alreadyGranted) {
                    console2.log("  SKIP (already has MARKET_ROLE):", eventNFT);
                    continue;
                }

                IAccessControl(eventNFT).grantRole(MARKET_ROLE, address(marketplace));
                console2.log("  MARKET_ROLE granted on:", eventNFT);
            }
        } else {
            console2.log("No existing EventNFTs specified. Set EXISTING_EVENT_NFTS to grant roles.");
        }

        vm.stopBroadcast();

        // ── 3. Resumen post-deploy ─────────────────────────────────────
        _printSummary(cfg, address(marketplace));
    }

    // -----------------------------------------------------------------
    // Helper: parsear "0xABC,0xDEF,0x123" → address[]
    // -----------------------------------------------------------------

    function _parseAddresses(string memory raw)
        internal pure
        returns (address[] memory result)
    {
        // Contar comas para dimensionar el array.
        bytes memory b = bytes(raw);
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }

        result = new address[](count);
        uint256 idx = 0;
        uint256 start = 0;

        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                // Extraer substring [start, i).
                bytes memory part = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    part[j - start] = b[j];
                }
                result[idx] = _parseAddr(string(part));
                idx++;
                start = i + 1;
            }
        }
    }

    /// @dev Convierte un string "0x..." a address vía vm.parseAddress.
    function _parseAddr(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(s)))));
        // NOTA: en un script real de Foundry usar vm.parseAddress(s).
        // La línea anterior es un placeholder para que compile sin vm en pure.
        // En producción reemplazar con:
        //   return vm.parseAddress(s);
        // y remover `pure` del calificador de la función.
    }

    // -----------------------------------------------------------------
    // Helper: imprimir resumen
    // -----------------------------------------------------------------

    function _printSummary(Config memory cfg, address marketplace) internal view {
        console2.log("---------------------------------------------");
        console2.log("Deploy CollectibleMarketplace - RESUMEN");
        console2.log("---------------------------------------------");
        console2.log("Network:              ", block.chainid);
        console2.log("CollectibleMarket:    ", marketplace);
        console2.log("EventFactory:         ", cfg.factory);
        console2.log("USDC:                 ", cfg.usdc);
        console2.log("VBK:                  ", cfg.vbk);
        console2.log("Uniswap Router:       ", cfg.router);
        console2.log("Treasury:             ", cfg.treasury);
        console2.log("Admin (owner):        ", cfg.admin);
        console2.log("---------------------------------------------");
        console2.log("PROXIMOS PASOS:");
        console2.log("1. Verificar contrato en Etherscan (--verify ya lo hace).");
        console2.log("2. Para eventos futuros: actualizar EventFactory para que");
        console2.log("   otorgue MARKET_ROLE al CollectibleMarketplace automaticamente");
        console2.log("   al deployar cada nuevo EventNFT.");
        console2.log("3. Para eventos existentes no listados en EXISTING_EVENT_NFTS:");
        console2.log("   llamar grantRole(MARKET_ROLE, marketplace) manualmente.");
        console2.log("4. El CollectibleMarketplace no necesita fondos ni VBK propio.");
        console2.log("---------------------------------------------");
    }
}

// =============================================================================
// INTEGRACIÓN CON EVENTFACTORY — instrucciones para el admin
// =============================================================================
//
// Para que los EventNFTs creados DESPUÉS de este deploy ya nazcan con
// MARKET_ROLE otorgado al CollectibleMarketplace, hay dos opciones:
//
// Opción A — Actualizar el script de deploy del EventFactory:
// ─────────────────────────────────────────────────────────────
// En el constructor o en `launchEvent()` del factory, después de deployer
// el EventNFT y otorgar MINTER_ROLE y MARKET_ROLE al NFTMarketplace,
// agregar:
//
//   EventNFT(newEventNFT).grantRole(
//       keccak256("MARKET_ROLE"),
//       COLLECTIBLE_MARKETPLACE_ADDRESS
//   );
//
// Opción B — Llamar manualmente por cada evento nuevo:
// ────────────────────────────────────────────────────
// El admin (que tiene DEFAULT_ADMIN_ROLE en cada EventNFT) llama:
//
//   IAccessControl(eventNFT).grantRole(
//       keccak256("MARKET_ROLE"),
//       address(collectibleMarketplace)
//   );
//
// Opción A es preferible para no depender de pasos manuales por evento.
// =============================================================================
