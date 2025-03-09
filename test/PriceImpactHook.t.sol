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
import {PriceImpactHook} from "../src/PriceImpactHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

contract TestPriceImpactHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using TickMath for int24;

    PriceImpactHook hook;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));

        vm.txGasPrice(10 gwei);

        // deploy our hook
        deployCodeTo("PriceImpactHook", abi.encode(manager), hookAddress);
        hook = PriceImpactHook(hookAddress);

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

        vm.roll(1);
    }

    function test_bothDirectionSwapIncreasedFee() public {
        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params1 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-20)
        });

        // ----------------------------------------------------------------------

        // 1. Conduct a swap in zeroForOne direction
        // This should just use `BASE_FEE` since it's the first swap
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params1, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromFirstBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        console.log("Output from first base fee swap: ", outputFromFirstBaseFeeSwap);

        // ----------------------------------------------------------------------

        // 2. Conduct a swap in !zeroForOne direction
        // This should use `MAX_FEE` since it's the first swap in this direction
        IPoolManager.SwapParams memory params2 = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(5)
        });

        uint256 balanceOfToken0Before = currency0.balanceOfSelf();
        swapRouter.swap(key, params2, testSettings, ZERO_BYTES);
        uint256 balanceOfToken0After = currency0.balanceOfSelf();
        uint256 outputFromFirstMaxFeeSwap = balanceOfToken0After - balanceOfToken0Before;

        assertGt(balanceOfToken0After, balanceOfToken0Before);

        console.log("Output from second max fee swap: ", outputFromFirstMaxFeeSwap);
    }
}
