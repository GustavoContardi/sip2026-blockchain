// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IUniswapV2Router02
 * @notice Interfaz mínima para consultar precios del pool VBK/USDC.
 *         Solo `getAmountsOut`, único método usado por OfferingNFT.
 */
interface IUniswapV2Router02 {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}
