// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {console} from "forge-std/console.sol";

contract PriorityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint256 public constant BASE_FACTOR = 100; // 1.0

    // The default base fees we will charge
    uint24 public constant BASE_FEE = 5000; // 0.5%

    // Keeping track of the moving average priority fee
    uint128 public movingAveragePriorityFee;
    // How many times has the moving average been updated?
    // Needed as the denominator to update it the next time based on the moving average formula
    uint104 public movingAveragePriorityFeeCount;

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        updateMovingAverage();
    }

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
            afterSwap: true, // TRUE
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

    function _beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = getFee();
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function _afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    // Update our moving average priority fee
    function updateMovingAverage() internal {
        uint128 priorityFee = uint128(tx.gasprice - block.basefee);

        // New Average = ((Old Average * # of Txns Tracked) + Current Priority Fee) / (# of Txns Tracked + 1)
        movingAveragePriorityFee = ((movingAveragePriorityFee * movingAveragePriorityFeeCount) + priorityFee)
            / (movingAveragePriorityFeeCount + 1);

        movingAveragePriorityFeeCount++;
    }

    function getFee() internal view returns (uint24) {
        uint128 priorityFee = uint128(tx.gasprice - block.basefee);

        // if priorityFee > movingAveragePriorityFee * 1.1, then half the fees
        if (priorityFee > (movingAveragePriorityFee * 11) / 10) {
            return BASE_FEE / 2;
        }

        // if priorityFee < movingAveragePriorityFee * 0.9, then double the fees
        if (priorityFee < (movingAveragePriorityFee * 9) / 10) {
            return BASE_FEE * 2;
        }

        return BASE_FEE;
    }
}
