// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {console} from "forge-std/console.sol";

contract DynamicPriorityFeeHook is BaseHook {
    using LPFeeLibrary for uint24;

    uint24 constant MIN_FEE = 5_000; // 0.5%
    uint24 constant MAX_FEE = 50_000; // 5.0%
    uint24 constant BASE_FEE = 10_000; // 1.0%

    uint8 constant BASE_FACTOR = 100; // 100%
    uint256 constant WEIGHT_OLD = 95; // 95% old value
    uint256 constant WEIGHT_NEW = 5; // 5% new value

    // Moving average of priority fee (in wei)
    // Should be calculated offchain and passed initially to constructor 
    uint256 public averagePriorityFee; 

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager, uint256 initialAveragePriorityFee) BaseHook(_poolManager) {
        averagePriorityFee = initialAveragePriorityFee;
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

    function _beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 priorityFee = tx.gasprice - block.basefee;
        uint24 calculatedFee = uint24(BASE_FEE * priorityFee / averagePriorityFee);
        averagePriorityFee = ((averagePriorityFee * WEIGHT_OLD) + (priorityFee * WEIGHT_NEW)) / BASE_FACTOR;
        uint24 fee = calculatedFee < MIN_FEE ? MIN_FEE : calculatedFee > MAX_FEE ? MAX_FEE : calculatedFee;
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }
}
