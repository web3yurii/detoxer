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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {BothDirectionSwapHook} from "../src/BothDirectionSwapHook.sol";
import {console} from "forge-std/console.sol";

contract BothDirectionSwapHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using TickMath for int24;

    PoolSwapTest.TestSettings testSettings = PoolSwapTest.TestSettings(false, false);

    // 0 - total, 1 - attacker, 2 - victim, 3 - regular
    mapping(uint256 => uint256) public swapCount;
    mapping(uint256 => uint256) public feeDelta;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint and approve all periphery contracts for two tokens
        currency0 = deployMintAndApproveCustomCurrency(18); // LAI
        currency1 = deployMintAndApproveCustomCurrency(6); // USDT

        // Deploy our hook with the proper flags

        // BothDirectionSwapHook
        address hookAddress = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("BothDirectionSwapHook", abi.encode(manager), hookAddress);
        IHooks hook = BothDirectionSwapHook(hookAddress);

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 200, 4266437714232750896327);
    }

    function testReplayHistoricalEvents() public {
        GraphEvent[] memory events = loadEvents();

        for (uint256 i = 0; i < events.length; i++) {
            GraphEvent memory e = events[i];

            // Start recording logs
            vm.recordLogs();

            vm.roll(e.blockNumber);

            vm.startPrank(address(this), e.origin);

            if (keccak256(abi.encodePacked(e.eventType)) == keccak256("swap")) {
                swap(e);
            } else {
                modifyLiquidity(e);
            }

            vm.stopPrank();

            // Fetch the logs
            Vm.Log[] memory logs = vm.getRecordedLogs();

            for (uint256 j = 0; j < logs.length; j++) {
                Vm.Log memory log = logs[j];

                if (log.topics[0] == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")) {
                    (,,,,, uint24 fee) = abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));

                    swapCount[0]++;
                    feeDelta[0] += fee;

                    if (e.sandwich == 1 || e.sandwich == 9) {
                        // 1 - front run, 9 - back run
                        swapCount[1]++;
                        feeDelta[1] += fee;
                    } else if (e.sandwich == 5) {
                        // 5 - victim
                        swapCount[2]++;
                        feeDelta[2] += fee;
                    } else {
                        // 0 - no sandwich, regular
                        swapCount[3]++;
                        feeDelta[3] += fee;
                    }
                }
            }
        }

        persisteResults();

        console.log("BothDirectionSwapHookTest - processed %s events", events.length);
    }

    function swap(GraphEvent memory e) internal {
        bool zeroForOne = e.amount0 < 0;
        int256 amount = zeroForOne ? e.amount0 : e.amount1;

        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(zeroForOne, amount, sqrtPriceLimitX96);

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    }

    function modifyLiquidity(GraphEvent memory e) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: e.tickLower,
                tickUpper: e.tickUpper,
                liquidityDelta: e.amount,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function loadEvents() internal view returns (GraphEvent[] memory) {
        string memory json = vm.readFile("data/graph/events.json");
        bytes memory data = vm.parseJson(json);
        return abi.decode(data, (GraphEvent[]));
    }

    function persisteResults() internal {
        string[4] memory users = ["total", "attacker", "victim", "regular"];

        string memory path = "data/reports/both-direction-results.csv";

        vm.writeFile(path, "totalSwapCount,totalFeeDelta,averageSwapFeeDelta\n");

        for (uint256 i = 0; i < 4; i++) {
            vm.writeLine(
                path,
                string.concat(
                    users[i],
                    ",",
                    vm.toString(swapCount[i]),
                    ",",
                    vm.toString(feeDelta[i]),
                    ",",
                    vm.toString(feeDelta[i] / swapCount[i])
                )
            );
        }
    }

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function caclDiff(uint256 b, uint256 a) internal pure returns (int256) {
        return a > b ? int256(a - b) : -int256(b - a);
    }

    function calcDiff(int256 b, int256 a) internal pure returns (int256) {
        return b - a;
    }

    function deployMintAndApproveCustomCurrency(uint8 decimals) internal returns (Currency currency) {
        MockERC20 token = new MockERC20("TEST", "TEST", decimals);
        token.mint(address(this), 2 ** 255);

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(address(token));
    }
}

struct GraphEvent {
    int256 amount;
    int256 amount0;
    int256 amount1;
    uint256 blockBaseFeePerGas;
    uint256 blockNumber;
    string eventType;
    uint256 gasPrice;
    uint256 gasUsed;
    uint256 logIndex;
    address origin;
    uint256 sandwich;
    uint256 sqrtPriceX96;
    int24 tick;
    int24 tickLower;
    int24 tickUpper;
    uint256 timestamp;
    bytes32 txId;
}
