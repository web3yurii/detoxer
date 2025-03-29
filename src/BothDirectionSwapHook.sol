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

contract BothDirectionSwapHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    // we charge sandwich x2 fee
    // base fee = 0.9% (quite less than usuall 1.0%)
    // 0.9 + 0.9 = 1.8% sandwich fee
    // 1.8% on front run + 1.8% on back run
    // 3.6% total on back run (since we can only identify sandwich on back run)    
    uint24 constant BASE_FEE = 9_000; // 0.9%
    uint24 constant MAX_FEE = 36_000; // 3.6%

    mapping(uint256 => uint256) public lastSwapBlock;

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
        uint256 oppositeSwapKey = getPackedKey(tx.origin, key.toId(), !params.zeroForOne);
        bool isBothDirectionSwap = block.number == lastSwapBlock[oppositeSwapKey];
        uint24 fee = isBothDirectionSwap ? MAX_FEE : BASE_FEE;
        lastSwapBlock[getPackedKey(tx.origin, key.toId(), params.zeroForOne)] = block.number;
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function getPackedKey(address user, PoolId poolId, bool direction) internal pure returns (uint256) {
        return (uint256(uint160(user)) << 96) | (uint256(PoolId.unwrap(poolId)) & ((1 << 96) - 1)) | (direction ? 1 : 0);
    }
}
