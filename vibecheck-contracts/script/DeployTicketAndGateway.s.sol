// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EventTicketNFT} from "../src/EventTicketNFT.sol";
import {PaymentGatewayWithTicket} from "../src/PaymentGatewayWithTicket.sol";

contract DeployTicketAndGateway is Script {
    function run() external returns (EventTicketNFT ticket, PaymentGatewayWithTicket gateway) {
        IERC20 usdc = IERC20(vm.envAddress("USDC_SEPOLIA"));
        address treasury = vm.envAddress("TREASURY");
        // Deployer (=treasury por default) será owner de ambos contratos.
        address deployer = vm.envOr("DEPLOYER", treasury);
        string memory name_ = vm.envOr("TICKET_NAME", string("VibeCheck Entry"));
        string memory symbol_ = vm.envOr("TICKET_SYMBOL", string("VIBE-TKT"));
        string memory baseURI_ = vm.envOr("TICKET_BASE_URI", string(""));

        vm.startBroadcast();
        ticket = new EventTicketNFT(name_, symbol_, deployer, baseURI_);
        gateway = new PaymentGatewayWithTicket(usdc, treasury, deployer, ticket);
        ticket.setMinter(address(gateway));
        vm.stopBroadcast();

        console.log("EventTicketNFT deployed at:           ", address(ticket));
        console.log("PaymentGatewayWithTicket deployed at: ", address(gateway));
        console.log("Owner of both (can pause/unpause):    ", deployer);
    }
}
