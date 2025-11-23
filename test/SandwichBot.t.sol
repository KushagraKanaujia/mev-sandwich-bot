
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/SandwichBot.sol";
import "../contracts/SimpleAMM.sol";
import "../contracts/TestTokens.sol";

contract SandwichBotTest is Test {
    uint256 constant DX_EXPECTED = 44_302_610_152_265_331_294;

    TokenX x;
    TokenY y;
    SimpleAMM amm;
    SandwichBot bot;

    address attacker = address(0xAAA);
    address victim   = address(0xBBB);

    function setUp() public {
        // deploy tokens
        x = new TokenX();
        y = new TokenY();

        // mint to AMM and users
        x.mint(address(this), 2_000 ether);
        y.mint(address(this), 2_000 ether);

        // initial pool: 1000 X, 1000 Y
        amm = new SimpleAMM(IERC20(address(x)), IERC20(address(y)), 1_000 ether, 1_000 ether);

        // fund pool
        x.transfer(address(amm), 1_000 ether);
        y.transfer(address(amm), 1_000 ether);

        // fund attacker and victim
        x.mint(attacker, 1_000 ether);
        x.mint(victim,  200 ether);

        // deploy bot from attacker
        vm.startPrank(attacker);
        bot = new SandwichBot(IERC20(address(x)), IERC20(address(y)));
        vm.stopPrank();

        // seed the bot with X it can spend
        vm.prank(attacker);
        x.transfer(address(bot), 600 ether);
    }

    function testComputeFrontRunDeterministicAmount() public {
        (uint112 rx, uint112 ry) = (amm.reserveX(), amm.reserveY());
        uint24 victimSlip = 1_000; // 10%
        uint256 dx = bot.computeFrontRunAmount(20 ether, victimSlip, rx, ry);
        assertEq(dx, DX_EXPECTED, "should equal closed-form optimum");
        // tighter victim slippage (0.5%) yields zero
        uint256 dx2 = bot.computeFrontRunAmount(20 ether, 50, rx, ry);
        assertEq(dx2, 0, "tight slippage should return 0");
        // zero inputs return zero
        assertEq(bot.computeFrontRunAmount(0, victimSlip, rx, ry), 0);
        assertEq(bot.computeFrontRunAmount(1, victimSlip, 0, ry), 0);
        assertEq(bot.computeFrontRunAmount(1, victimSlip, rx, 0), 0);
        // slippage too high returns zero
        assertEq(bot.computeFrontRunAmount(20 ether, 10_000, rx, ry), 0);
    }

    function testComputeFrontRunZeroWhenSlippageTooTight() public {
        (uint112 rx, uint112 ry) = (amm.reserveX(), amm.reserveY());
        uint256 dx = bot.computeFrontRunAmount(5 ether, 0, rx, ry);
        assertEq(dx, 0, "should refuse when slippage tolerance is zero");
    }

    function testFrontAndBackRunProfitableAndPaysOwner() public {
        uint256 dxVictim = 20 ether;
        (uint112 rx, uint112 ry) = (amm.reserveX(), amm.reserveY());

        vm.startPrank(attacker);
        uint24 victimSlip = 1_000; // 10%
        uint256 dxFront = bot.computeFrontRunAmount(dxVictim, victimSlip, rx, ry);
        assertEq(dxFront, DX_EXPECTED, "front-run size should match closed form");
        uint256 xBefore = x.balanceOf(attacker);
        bot.frontRun(amm, dxFront);
        vm.stopPrank();

        // victim trade in the middle (X -> Y)
        vm.startPrank(victim);
        x.approve(address(amm), dxVictim);
        amm.swapXForY(dxVictim, victim);
        vm.stopPrank();

        vm.startPrank(attacker);
        bot.backRun(amm);
        uint256 xAfter = x.balanceOf(attacker);
        vm.stopPrank();

        assertGt(xAfter, xBefore, "owner should profit and receive X");
    }

    function testVictimSlippageBinding() public {
        (uint112 rx, uint112 ry) = (amm.reserveX(), amm.reserveY());
        uint256 dx = bot.computeFrontRunAmount(20 ether, 50, rx, ry); // 0.5% victim slippage
        assertEq(dx, 0, "tight slippage should nullify attack");
    }

    function testFrontRunZeroNoRevert() public {
        uint256 xBefore = x.balanceOf(address(bot));
        vm.prank(attacker);
        bot.frontRun(amm, 0);
        uint256 xAfter = x.balanceOf(address(bot));
        assertEq(xAfter, xBefore, "frontRun(0) should be no-op");
    }

    function testBackRunZeroNoRevert() public {
        uint256 yBefore = y.balanceOf(address(bot));
        vm.prank(attacker);
        bot.backRun(amm);
        uint256 yAfter = y.balanceOf(address(bot));
        assertEq(yAfter, yBefore, "backRun with 0 Y should be no-op");
    }

    function testFrontRunRevertsWhenInsufficient() public {
        uint256 bal = x.balanceOf(address(bot));
        vm.expectRevert();
        vm.prank(attacker);
        bot.frontRun(amm, bal + 1);
    }
}
