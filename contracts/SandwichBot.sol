
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SimpleAMM.sol";
import "./IERC20.sol";

/**
 * @title SandwichBot
 * @notice A simple MEV sandwich attacker.
 */
contract SandwichBot {
    IERC20 public tokenX;
    IERC20 public tokenY;
    address public owner;

    uint24 private constant _FEE_BPS = 30;
    uint24 private constant _BPS = 10_000;

    constructor(IERC20 _x, IERC20 _y) {
        tokenX = _x;
        tokenY = _y;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /**
     * @notice Compute the front-run amount (in X) based on:
     *   - dxVictim: victim's input amount (X)
     *   - victimSlippageBps: victim's max slippage tolerance (basis points)
     *   - reserveX, reserveY: AMM pool reserves
     *
     * Requirements:
     *   - Must return a non-negative number
     *   - Use the victim slippage constraint (quadratic) to get the largest fee-adjusted X-in that still lets the victim clear; convert back to gross dxFront, then require profit > 0
     *   - May return 0 if the sandwich would be unprofitable or violate victim slippage
     */
    function computeFrontRunAmount(
        uint256 dxVictim,
        uint24 victimSlippageBps,
        uint112 reserveX,
        uint112 reserveY
    ) public pure returns (uint256 dxFront) {
        if (reserveX == 0 || reserveY == 0 || dxVictim == 0 || victimSlippageBps >= _BPS) {
            return 0;
        }

        uint256 x0 = uint256(reserveX);
        uint256 y0 = uint256(reserveY);
        uint256 dv = _applyFee(dxVictim);
        if (dv == 0) return 0;

        uint256 victimMinOut = _minVictimOut(dxVictim, victimSlippageBps, x0, y0);
        if (victimMinOut == 0) return 0;

        // Solve quadratic inequality: victimMinOut * x1^2 + victimMinOut * dv * x1 - k * dv <= 0
        // to find maximum x1 that satisfies victim's slippage constraint
        // Scale calculations by 1e9 to prevent overflow for large token amounts
        uint256 sqrtArg;
        {
            uint256 k_scaled = (x0 / 1e9) * (y0 / 1e9);
            uint256 vm_scaled = victimMinOut / 1e9;
            uint256 dv_scaled = dv / 1e9;

            uint256 bSq_scaled = vm_scaled * vm_scaled * dv_scaled * dv_scaled;
            uint256 fourAC_scaled = 4 * vm_scaled * k_scaled * dv_scaled;

            sqrtArg = bSq_scaled + fourAC_scaled;
        }

        uint256 sqrtVal_scaled = _sqrt(sqrtArg);
        uint256 b_scaled = (victimMinOut / 1e9) * (dv / 1e9);

        if (sqrtVal_scaled <= b_scaled) return 0;

        // x1Max = (sqrt(b^2 + 4ac) - b) / 2a, then scale back
        uint256 x1Max = (sqrtVal_scaled - b_scaled) * 1e9 / (2 * (victimMinOut / 1e9));

        if (x1Max <= x0) return 0;

        // Convert fee-adjusted amount back to gross input
        uint256 dfMax = x1Max - x0;
        dxFront = (dfMax * _BPS) / (_BPS - _FEE_BPS);

        // Verify profitability before returning
        uint256 profit = _simulateProfit(dxFront, dxVictim, victimSlippageBps, reserveX, reserveY);

        if (profit == 0) return 0;

        return dxFront;
    }

    /**
     * @notice Execute attacker’s front-run trade (X → Y).
     * The bot must:
     *   - Spend the bot contract's existing tokenX balance (tests pre-fund the contract)
     *   - Approve SimpleAMM to spend dxFront
     *   - Call amm.swapXForY(dxFront, address(this))
     */
    function frontRun(SimpleAMM amm, uint256 dxFront) external onlyOwner {
        if (dxFront == 0) return;

        tokenX.approve(address(amm), dxFront);
        amm.swapXForY(dxFront, address(this));
    }

    /**
     * @notice After the victim trade, convert ALL tokenY back to tokenX.
     * Steps:
     *   - Compute yBal = tokenY.balanceOf(address(this))
     *   - Approve SimpleAMM
     *   - Call amm.swapYForX(yBal, address(this))
     */
    function backRun(SimpleAMM amm) external onlyOwner {
        uint256 yBal = tokenY.balanceOf(address(this));
        if (yBal == 0) return;

        tokenY.approve(address(amm), yBal);
        amm.swapYForX(yBal, owner);
    }

    // ---------- helper functions (fill these in or inline your logic) ----------

    function _applyFee(uint256 amount) internal pure returns (uint256) {
        return amount == 0 ? 0 : amount * (_BPS - _FEE_BPS) / _BPS;
    }

    function _minVictimOut(
        uint256 dxVictim,
        uint24 victimSlippageBps,
        uint256 reserveX,
        uint256 reserveY
    ) internal pure returns (uint256) {
        if (dxVictim == 0 || reserveX == 0 || reserveY == 0) return 0;
        if (victimSlippageBps > _BPS) return 0;
        uint256 dv = dxVictim * (_BPS - _FEE_BPS) / _BPS;
        uint256 idealOut = dv * reserveY / reserveX;
        if (victimSlippageBps == 0) return idealOut;
        return idealOut * (_BPS - victimSlippageBps) / _BPS;
    }

    function _simulateProfit(
        uint256 dxFront,
        uint256 dxVictim,
        uint24 victimSlippageBps,
        uint112 reserveX,
        uint112 reserveY
    ) internal pure returns (uint256) {
        uint256 x0 = reserveX;
        uint256 y0 = reserveY;
        if (x0 == 0 || y0 == 0 || dxFront == 0 || dxVictim == 0) return 0;
        uint256 k = x0 * y0;
        if (k == 0) return 0;

        uint256 df = _applyFee(dxFront);
        if (df == 0) return 0;
        uint256 x1 = x0 + df;
        uint256 y1 = k / x1;
        uint256 yFront = y0 - y1;
        if (yFront == 0) return 0;

        uint256 victimMinOut = _minVictimOut(dxVictim, victimSlippageBps, x0, y0);
        uint256 dv = _applyFee(dxVictim);
        if (dv == 0) return 0;
        uint256 x2 = x1 + dv;
        uint256 y2 = k / x2;
        uint256 victimOut = y1 - y2;
        if (victimOut < victimMinOut) return 0;

        uint256 yInNet = _applyFee(yFront);
        if (yInNet == 0) return 0;
        uint256 x3 = k / (y2 + yInNet);
        uint256 xBack = x2 - x3;
        return xBack > dxFront ? xBack - dxFront : 0;
    }

    function _sqrt(uint256 radicand) internal pure returns (uint256 root) {
        if (radicand == 0) return 0;
        uint256 z = (radicand + 1) / 2;
        root = radicand;
        while (z < root) {
            root = z;
            z = (radicand / z + z) / 2;
        }
    }
}
