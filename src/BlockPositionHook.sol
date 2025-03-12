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

contract BlockPositionHook is BaseHook {
    using LPFeeLibrary for uint24;

    uint256 private constant SAME_TX__SLOT = 0x01; // Define transient storage slot

    uint24 constant MIN_FEE = 4000; // 0.4%
    uint24 constant MAX_FEE = 6000; // 0.6%

    uint256 constant DECREASE_PERCENTAGE = 95; // 95% old value

    uint256 public averagePriorityFee; // Moving average of priority fee (in wei)

    error MustUseDynamicFee();

    struct GlobalState {
        uint104 latestBlock; // 104 bits
        uint128 latestTxBlockIndex; // 128 bits
        uint24 latestFee; // 24 bits
    }

    GlobalState private globalState;

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

    function _beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        GlobalState memory gs = globalState;

        if (gs.latestBlock < block.number) {
            // new block - reset fee
            gs.latestBlock = uint104(block.number);
            gs.latestTxBlockIndex = 0;
            gs.latestFee = MAX_FEE;
            startTransactionTracking();
        } else if (!isSameTransaction()) {
            // same block, different transaction - decrease fee
            gs.latestTxBlockIndex++;
            uint24 calculatedFee = uint24(gs.latestFee * DECREASE_PERCENTAGE / 100); // 90% old value
            gs.latestFee = calculatedFee > MIN_FEE ? calculatedFee : MIN_FEE;
        } // same block and same transaction, we keep the same fee

        globalState = gs;

        console.log("Fee = %d", gs.latestFee);

        uint24 feeWithFlag = gs.latestFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function startTransactionTracking() internal {
        assembly {
            tstore(SAME_TX__SLOT, 1) // Store a value in transient storage
        }
    }

    function isSameTransaction() public view returns (bool) {
        uint256 storedValue;
        assembly {
            storedValue := tload(SAME_TX__SLOT) // Load from transient storage
        }
        return storedValue == 1;
    }

    function clearTransactionTracking() external {
        assembly {
            tstore(SAME_TX__SLOT, 0) // Clear the value in transient storage
        }
    }

}
