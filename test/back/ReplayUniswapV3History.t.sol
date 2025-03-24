// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {console} from "forge-std/console.sol";

contract ReplayUniswapV3History is Test, Deployers {
    using StateLibrary for IPoolManager;
    using TickMath for int24;

    IHooks hook;

    struct AllEvent {
        uint256 blockNumber;
        string eventType;
        uint256 gasPrice;
        uint256 gasUsed;
        uint256 logIndex;
        address origin;
        uint256 timestamp;
        bytes32 txId;
    }

    struct SwapEvent {
        int256 amount0;
        int256 amount1;
        uint256 amountUSD;
        uint256 blockNumber;
        uint256 logIndex;
        uint256 sqrtPriceX96;
        int24 tick;
    }

    struct MintEvent {
        int256 amount;
        uint256 amount0;
        uint256 amount1;
        uint256 blockNumber;
        uint256 logIndex;
        int24 tickLower;
        int24 tickUpper;
    }

    struct BurnEvent {
        int256 amount;
        uint256 amount0;
        uint256 amount1;
        uint256 blockNumber;
        uint256 logIndex;
        int24 tickLower;
        int24 tickUpper;
    }

    function setUp() public {
        console.log("Setting up test");
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        // deployMintAndApprove2Currencies();

        currency0 = deployMintAndApproveCustomCurrency(6, 2 ** 255);
        currency1 = deployMintAndApproveCustomCurrency(18, 2 ** 255);

        hook = IHooks(address(0));

        // Initialize a pool
        (key,) = initPool(currency0, currency1, hook, 500, 10, 1350174849792634181862360983626536);
    }

    uint256 blockN;

    function testReplayHistoricalEvents() public {
        AllEvent[] memory events = loadAllEvents();
        console.log(events.length);
        SwapEvent[] memory swapEvents = loadSwapEvents();
        console.log(swapEvents.length);
        MintEvent[] memory mintEvents = loadMintEvents();
        console.log(mintEvents.length);
        BurnEvent[] memory burnEvents = loadBurnEvents();
        console.log(burnEvents.length);

        uint256 swapIndex = 0;
        uint256 mintIndex = 0;
        uint256 burnIndex = 0;

        for (uint256 i = 0; i < events.length; i++) {
            console.log("Processing event %d...", i);

            AllEvent memory e = events[i];

            // check state before the operation
            uint128 liqBefore = manager.getLiquidity(key.toId());
            console.log("Liquidity before: %d", liqBefore);
            (uint160 priceBefore, int24 tickBefore,,) = manager.getSlot0(key.toId());
            console.log("Price before: %d", priceBefore);
            console.log("Tick before: %d", tickBefore);

            uint256 balance0before = currency0.balanceOfSelf();
            uint256 balance1before = currency1.balanceOfSelf();

            if (keccak256(abi.encodePacked(e.eventType)) == keccak256("swap")) {
                console.log("-- Executing SWAP with index %d...", swapIndex);
                SwapEvent memory s = swapEvents[swapIndex++];

                bool zeroForOne = s.amount0 < 0;

                int256 amountSpecified = zeroForOne ? s.amount0 : s.amount1;

                console.log("Amount0: %d", s.amount0);
                console.log("Amount1: %d", s.amount1);
                console.log("Expected price: %d", s.sqrtPriceX96);
                console.log("Expected tick: %d", s.tick);
                // uint160 sqrtPriceLimitX96 = applySlippageBuffer(s.sqrtPriceX96, zeroForOne, 50); // 0.5% slippage

                IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: uint160(s.sqrtPriceX96)
                });

                swapRouter.swap(
                    key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
                );
            } else if (keccak256(abi.encodePacked(e.eventType)) == keccak256("mint")) {
                console.log("-- Executing MINT with index %d...", mintIndex);
                MintEvent memory m = mintEvents[mintIndex++];

                console.log("Add liquidity amount: %d", m.amount);
                console.log("Tick lower: %d", m.tickLower);
                console.log("Tick upper: %d", m.tickUpper);

                modifyLiquidityRouter.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: m.tickLower,
                        tickUpper: m.tickUpper,
                        liquidityDelta: m.amount,
                        salt: bytes32(0)
                    }),
                    ZERO_BYTES
                );
            } else if (keccak256(abi.encodePacked(e.eventType)) == keccak256("burn")) {
                console.log("-- Executing BURN with index %d...", burnIndex);
                BurnEvent memory b = burnEvents[burnIndex++];

                console.log("Remove liquidity amount: %d", b.amount);
                console.log("Tick lower: %d", b.tickLower);
                console.log("Tick upper: %d", b.tickUpper);

                // Remove some liquidity
                modifyLiquidityRouter.modifyLiquidity(
                    key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: b.tickLower,
                        tickUpper: b.tickUpper,
                        liquidityDelta: b.amount,
                        salt: bytes32(0)
                    }),
                    ZERO_BYTES
                );
            }
            uint128 liqAfter = manager.getLiquidity(key.toId());
            console.log("Liquidity after: %d", liqAfter);
            (uint160 priceAfter, int24 tickAfter,,) = manager.getSlot0(key.toId());
            console.log("Price after: %d", priceAfter);
            console.log("Tick after: %d", tickAfter);

            // check difference in balances
            uint256 balance0After = currency0.balanceOfSelf();
            uint256 balance1After = currency1.balanceOfSelf();
            console.log("Balance0 diff: %d", calculateDiff(balance0After, balance0before));
            console.log("Balance1 diff: %d", calculateDiff(balance1After, balance1before));
            console.log("Liquidity diff: %d", calculateDiff(liqAfter, liqBefore));
            console.log("Price diff: %d", calculateDiff(priceAfter, priceBefore));
            console.log("Tick diff: %d", calculateDiff(tickAfter, tickBefore));
            console.log("-------------------------------------------------");
        }
    }

    function applySlippageBuffer(uint256 sqrtPriceFinalX96, bool zeroForOne, uint256 slippageBps)
        public
        pure
        returns (uint160)
    {
        uint256 delta = (sqrtPriceFinalX96 * slippageBps) / 10_000;

        if (zeroForOne) {
            // Price is going down, so limit is lower than final
            return uint160(sqrtPriceFinalX96 - delta);
        } else {
            // Price is going up, so limit is higher than final
            return uint160(sqrtPriceFinalX96 + delta);
        }
    }

    function calculateDiff(uint256 a, uint256 b) internal pure returns (int256) {
        return a > b ? int256(a - b) : -int256(b - a);
    }

    function calculateDiff(int24 a, int24 b) internal pure returns (int256) {
        return a > b ? int256(a - b) : -int256(b - a);
    }

    function loadAllEvents() internal view returns (AllEvent[] memory) {
        string memory json = vm.readFile("data/all.json");
        bytes memory data = vm.parseJson(json);
        return abi.decode(data, (AllEvent[]));
    }

    function loadSwapEvents() internal view returns (SwapEvent[] memory) {
        string memory json = vm.readFile("data/swaps.json");
        bytes memory data = vm.parseJson(json);
        return abi.decode(data, (SwapEvent[]));
    }

    function loadMintEvents() internal view returns (MintEvent[] memory) {
        string memory json = vm.readFile("data/mints.json");
        bytes memory data = vm.parseJson(json);
        return abi.decode(data, (MintEvent[]));
    }

    function loadBurnEvents() internal view returns (BurnEvent[] memory) {
        string memory json = vm.readFile("data/burns.json");
        bytes memory data = vm.parseJson(json);
        return abi.decode(data, (BurnEvent[]));
    }
}
