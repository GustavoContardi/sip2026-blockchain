// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockVBK
 * @notice Réplica mínima del comportamiento de VbkToken para tests:
 *         quema `burnRateBps` en cada transferencia P2P salvo que `from` o `to`
 *         estén exentos, o que sea mint/burn. Permite verificar que StakingVault
 *         acredita el monto realmente recibido.
 */
contract MockVBK is ERC20 {
    uint256 public burnRateBps; // 200 = 2%
    mapping(address => bool) public feeExempt;

    constructor() ERC20("Mock VBK", "VBK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBurnRate(uint256 bps) external {
        require(bps <= 10_000, "bps>100%");
        burnRateBps = bps;
    }

    function setFeeExempt(address account, bool value) external {
        feeExempt[account] = value;
    }

    // OZ v5: hook único de transferencia.
    function _update(address from, address to, uint256 value) internal override {
        if (
            from == address(0) ||
            to == address(0) ||
            burnRateBps == 0 ||
            feeExempt[from] ||
            feeExempt[to]
        ) {
            super._update(from, to, value);
            return;
        }
        uint256 burnAmount = (value * burnRateBps) / 10_000;
        super._update(from, to, value - burnAmount);
        super._update(from, address(0), burnAmount);
    }
}
