
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IERC20.sol";

/**
 * @title SimpleAMM
 * @notice Minimal constant-product AMM (Uniswap v2 style) for HW4.
 */
contract SimpleAMM {
    IERC20 public tokenX;
    IERC20 public tokenY;
    uint24 public constant FEE_BPS = 30; // 0.3% fee (basis points)
    uint24 public constant BPS = 10_000;

    uint112 public reserveX;
    uint112 public reserveY;

    constructor(IERC20 _x, IERC20 _y, uint112 _rx, uint112 _ry) {
        tokenX = _x;
        tokenY = _y;
        reserveX = _rx;
        reserveY = _ry;
    }

    function getReserves() external view returns (uint112, uint112) {
        return (reserveX, reserveY);
    }

    /// @notice swap exact X for Y
    function swapXForY(uint256 amountIn, address to) external returns (uint256 amountOut) {
        require(amountIn > 0, "amountIn=0");

        // pull X
        require(tokenX.transferFrom(msg.sender, address(this), amountIn), "transferFrom X failed");

        // apply fee
        uint256 amountInAfterFee = amountIn * (BPS - FEE_BPS) / BPS;

        uint256 x = uint256(reserveX) + amountInAfterFee;
        uint256 k = uint256(reserveX) * uint256(reserveY);
        uint256 y = k / x;
        amountOut = uint256(reserveY) - y;

        reserveX = uint112(x);
        reserveY = uint112(y);

        require(tokenY.transfer(to, amountOut), "transfer Y failed");
    }

    /// @notice swap exact Y for X
    function swapYForX(uint256 amountIn, address to) external returns (uint256 amountOut) {
        require(amountIn > 0, "amountIn=0");

        require(tokenY.transferFrom(msg.sender, address(this), amountIn), "transferFrom Y failed");

        uint256 amountInAfterFee = amountIn * (BPS - FEE_BPS) / BPS;

        uint256 y = uint256(reserveY) + amountInAfterFee;
        uint256 k = uint256(reserveX) * uint256(reserveY);
        uint256 x = k / y;
        amountOut = uint256(reserveX) - x;

        reserveY = uint112(y);
        reserveX = uint112(x);

        require(tokenX.transfer(to, amountOut), "transfer X failed");
    }
}
