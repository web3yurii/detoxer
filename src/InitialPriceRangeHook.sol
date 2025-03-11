// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

contract InitialPriceRangeHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint24 constant MAX_FEE = 15000; // 1.5%
    uint24 constant MID_FEE = 10000; // 1.0%
    uint24 constant MIN_FEE = 5000; // 0.5%

    uint24 constant BASE_FEE_WINDOW_PERCENTAGE = 5;

    struct PoolState {
        uint160 blockStartPrice;
        uint96 lastSwapBlock;
    }

    error MustUseDynamicFee();

    mapping(PoolId => PoolState) public poolState;

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // TRUE
            afterInitialize: true, // TRUE
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // TRUE
            afterSwap: true, // TRUE
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // TRUE
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

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        poolManager.updateDynamicLPFee(key, 0);
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolState storage state = poolState[poolId];
        (uint160 beforePrice,,,) = poolManager.getSlot0(poolId);

        if (state.lastSwapBlock < block.number) {
            state.blockStartPrice = beforePrice;
            state.lastSwapBlock = uint96(block.number);
        }

        // store before price to transient storage
        storeBeforePrice(poolId, beforePrice);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (uint160 afterPrice,,,) = poolManager.getSlot0(poolId);

        uint24 fee =
            calculateFee(poolState[poolId].blockStartPrice, getBeforePrice(poolId), afterPrice, params.zeroForOne);

        // calculate fee delta
        uint128 feeDelta;
        {
            int128 amount = params.zeroForOne ? delta.amount1() : delta.amount0();

            console.log("amount: %d", amount);
            console.log("fee: %d", fee);

            feeDelta = uint128(amount) * fee / 1e6;
        }

        console.log("feeDelta: %d", feeDelta);

        // settle balances - direct donation to the pool
        if (params.zeroForOne) {
            poolManager.donate(key, 0, feeDelta, "");
            
        } else {
            poolManager.donate(key, feeDelta, 0, "");
        }

        return (this.afterSwap.selector, int128(feeDelta));
    }

    function calculateFee(uint160 blockStartPrice, uint160 beforePrice, uint160 afterPrice, bool zeroForOne)
        internal
        pure
        returns (uint24)
    {

        uint160 priceChange = beforePrice > afterPrice ? beforePrice - afterPrice : afterPrice - beforePrice;
        uint160 midFeeWindow = priceChange * BASE_FEE_WINDOW_PERCENTAGE / 100;

        uint24 fee;

        if (zeroForOne) {
            // move to the left
            if (beforePrice > blockStartPrice + midFeeWindow) {
                fee = MAX_FEE; // very good initial price - high fee
            } else if (beforePrice < blockStartPrice - midFeeWindow) {
                fee = MIN_FEE; // very bad initial price - low fee
            } else {
                fee = MID_FEE; // reasonable initial price - mid fee
            }
        } else {
            // move to the right
            if (beforePrice < blockStartPrice - midFeeWindow) {
                fee = MAX_FEE; // very good initial price - high fee
            } else if (beforePrice > blockStartPrice + midFeeWindow) {
                fee = MIN_FEE; // very bad initial price - low fee
            } else {
                fee = MID_FEE; // reasonable initial price - mid fee
            }
        }

        return fee;
    }

    function storeBeforePrice(PoolId poolId, uint160 beforePrice) internal {
        assembly {
            tstore(poolId, beforePrice)
        }
    }

    function getBeforePrice(PoolId poolId) internal view returns (uint160 beforePrice) {
        assembly {
            beforePrice := tload(poolId)
        }
    }
}
