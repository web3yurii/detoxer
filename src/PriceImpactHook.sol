// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

contract PriceImpactHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint24 constant BASE_FEE = 5000; // 0.5%

    struct PoolState {
        uint160 blockStartPrice;
        uint96 lastSwapBlock;
    }

    mapping(PoolId => PoolState) public poolState;

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // TRUE
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // TRUE
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `SwapFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = BASE_FEE; // by default we assume the price will go further away from the start price

        PoolState storage state = poolState[key.toId()];
        (uint160 currentPrice,,,) = poolManager.getSlot0(key.toId());

        // if we are on a new block, reset the start price
        if (state.lastSwapBlock < block.number) {
            state.blockStartPrice = currentPrice;
            state.lastSwapBlock = uint96(block.number);
        } else {
            if (
                // Zero fee if:
                // 1. current price is already at price limit (no price impact)
                // 2. block start price is at price limit (move price back)
                // 3. we move to the left towards the start block price
                // 4. we move to the right towards the start block price
                params.sqrtPriceLimitX96 == currentPrice || params.sqrtPriceLimitX96 == state.blockStartPrice
                    || (
                        params.zeroForOne && state.blockStartPrice < params.sqrtPriceLimitX96
                            && params.sqrtPriceLimitX96 < currentPrice
                    )
                    || (
                        !params.zeroForOne && currentPrice < params.sqrtPriceLimitX96
                            && params.sqrtPriceLimitX96 < state.blockStartPrice
                    )
            ) {
                fee = 0;
            } else if (
                // Adjusted fee if:
                // 1. we move to the left, cross the start price, and move futher (pay only for the part that is further)
                params.zeroForOne && currentPrice > state.blockStartPrice
                    && params.sqrtPriceLimitX96 < state.blockStartPrice
            ) {
                fee = uint24(
                    fee * (state.blockStartPrice - params.sqrtPriceLimitX96) / (currentPrice - params.sqrtPriceLimitX96)
                );
            } else if (
                // 2. we move to the right, cross the start price, and move futher (pay only for the part that is further)
                !params.zeroForOne && currentPrice < state.blockStartPrice
                    && params.sqrtPriceLimitX96 > state.blockStartPrice
            ) {
                fee = uint24(
                    fee * (params.sqrtPriceLimitX96 - state.blockStartPrice) / (params.sqrtPriceLimitX96 - currentPrice)
                );
            }
        }

        console.log("fee", fee);

        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }
}
