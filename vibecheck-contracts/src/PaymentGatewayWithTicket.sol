// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PaymentGateway} from "./PaymentGateway.sol";
import {EventTicketNFT} from "./EventTicketNFT.sol";

/**
 * @title PaymentGatewayWithTicket
 * @notice Cada pago USDC mintea una entrada NFT al payer.
 *         El gateway debe ser el `minter` del EventTicketNFT para poder mintear.
 *         Hereda Pausable: si el owner pausa el gateway, los pagos revierten.
 */
contract PaymentGatewayWithTicket is PaymentGateway {
    EventTicketNFT public immutable ticket;

    constructor(IERC20 _usdc, address _treasury, address _owner, EventTicketNFT _ticket)
        PaymentGateway(_usdc, _treasury, _owner)
    {
        ticket = _ticket;
    }

    function _onPaid(address payer, uint256, /* amount */ bytes32 action) internal override {
        ticket.mintTicket(payer, action);
    }
}
