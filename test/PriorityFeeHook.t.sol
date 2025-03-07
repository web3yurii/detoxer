// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PriorityFeeHook} from "../src/PriorityFeeHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

contract TestPriorityFeeHookHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    PriorityFeeHook hook;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress =
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));

        // Set base fee = 2 gwei
        vm.fee(2 gwei);
        // Set gas price = 12 gwei
        vm.txGasPrice(12 gwei);
        // Prioprity fee = 10 gwei (gasprice - basefee)

        // deploy our hook
        deployCodeTo("PriorityFeeHook", abi.encode(manager), hookAddress);
        hook = PriorityFeeHook(hookAddress);

        // Initialize a pool
        (key,) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1
        );

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_feeUpdatesWithPriorityFee() public {
        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Current priority fee is 10 gwei
        // Moving average should also be 10
        uint128 priorityFee = uint128(tx.gasprice - block.basefee);
        uint128 movingAveragePriorityFee = hook.movingAveragePriorityFee();
        uint104 movingAveragePriorityFeeCount = hook.movingAveragePriorityFeeCount();
        assertEq(priorityFee, 10 gwei);
        assertEq(movingAveragePriorityFee, 10 gwei);
        assertEq(movingAveragePriorityFeeCount, 1);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 1. Conduct a swap at priority fee = 10 gwei
        // This should just use `BASE_FEE` since the priority fee is the same as the current average
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Our moving average shouldn't have changed
        // only the count should have incremented
        movingAveragePriorityFee = hook.movingAveragePriorityFee();
        movingAveragePriorityFeeCount = hook.movingAveragePriorityFeeCount();
        assertEq(movingAveragePriorityFee, 10 gwei);
        assertEq(movingAveragePriorityFeeCount, 2);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 2. Conduct a swap at lower priority fee = 4 gwei
        // This should have a higher transaction fees
        vm.txGasPrice(6 gwei); // block.basefee = 2 gwei, priority fee = 4 gwei
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();

        uint256 outputFromIncreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Our moving average should now be (10 + 10 + 4) / 3 = 8 Gwei
        movingAveragePriorityFee = hook.movingAveragePriorityFee();
        movingAveragePriorityFeeCount = hook.movingAveragePriorityFeeCount();
        assertEq(movingAveragePriorityFee, 8 gwei);
        assertEq(movingAveragePriorityFeeCount, 3);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 3. Conduct a swap at higher priority fee = 12 gwei
        // This should have a lower transaction fees
        vm.txGasPrice(14 gwei); // block.basefee = 2 gwei, priority fee = 12 gwei
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();

        uint256 outputFromDecreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Our moving average should now be (10 + 10 + 4 + 12) / 4 = 9 Gwei
        movingAveragePriorityFee = hook.movingAveragePriorityFee();
        movingAveragePriorityFeeCount = hook.movingAveragePriorityFeeCount();

        assertEq(movingAveragePriorityFee, 9 gwei);
        assertEq(movingAveragePriorityFeeCount, 4);

        // ------

        // 4. Check all the output amounts

        console.log("Base Fee Output", outputFromBaseFeeSwap);
        console.log("Increased Fee Output", outputFromIncreasedFeeSwap);
        console.log("Decreased Fee Output", outputFromDecreasedFeeSwap);

        assertGt(outputFromDecreasedFeeSwap, outputFromBaseFeeSwap);
        assertGt(outputFromBaseFeeSwap, outputFromIncreasedFeeSwap);
    }
}
