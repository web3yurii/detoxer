# 🧼 Detoxer — MEV Protection Hooks for Uniswap v4

**Detoxer** is a suite of custom Uniswap v4 hooks designed to **discourage MEV attacks (especially sandwich)**, **punish attackers**, **Revard victims**, **protect regular users**, and **Ensure LP have the same fee collected** by dynamically adjusting swap fees. Each hook independently targets a different class of exploit pattern. These hooks can be combined to create a powerful complex hook to fight against MEV attacks.

---

## 🔌 Hooks Overview

Located in `src/`, each hook is plug-and-play compatible with Uniswap v4’s `Hook` system.

### 1. `InitialPriceRangeHook`

- **Goal**: Deter price manipulation during the each block.

- **How it works**:
  - Captures the **initial price** at the start of each block (on the first swap).
  - Calculates how much the price shifts during subsequent swaps within the same block.
  - Applies a **dynamic fee** based on how favorable (or suspicious) the price movement is:
    - 📈 **2.0% fee** — when a trade aggressively pushes the price in a profitable direction (potential attacker).
    - ⚖️ **0.9% fee** — for moderate or neutral price shifts.
    - 📉 **0.5% fee** — when a trade worsens the price (likely a victim).

- **Why it matters**: Attackers often front-run early in a block and than back-run later, both part of sandwich usually have better price than victim's one. By making price-moving trades more expensive, this hook disincentivizes predatory behavior and protects regular users.


### 2. `DynamicPriorityFeeHook`

- **Goal**: Dynamically adjust swap fees based on the transaction’s **priority fee (tip)** to target MEV-style behavior.
  
- **How it works**:
  - Measures the difference between `tx.gasprice` and `block.basefee` to get the **priority fee**.
  - Maintains a **moving average** of recent priority fees.
  - If a user is paying **higher-than-normal priority fees**, it's treated as a signal of MEV or aggressive behavior.
  - Swap fee is adjusted **proportionally**:
    - 🔺 High tip = **higher fee** (up to 5.0%)
    - ⚖️ Normal tip = **base fee** (1.0%)
    - 🔻 Low tip = **minimum fee** (0.5%)
  - The priority fee average is updated over time with a **smooth exponential moving average (EMA)**.

- **Why it matters**: MEV bots often pay abnormally high tips to get their txs included faster. This hook detects and **charges them more**, while protecting normal users with lower fees.

Requires the pool to be configured with an initial average priority fee (passed to the constructor).


### 3. `BothDirectionSwapHook`

- **Goal**: Detect and penalize sandwich attacks by identifying when a trader swaps in **both directions** within the same block.

- **How it works**:
  - Tracks the most recent block in which each user swapped in a specific direction (`zeroForOne` or `oneForZero`).
  - If a user swaps in the **opposite direction** in the **same block**, the hook considers it a sandwich and applies a **higher fee**.
  - Fee logic:
    - 🔄 **Same-direction swap**: charged **0.9%** (`BASE_FEE`)
    - 🔁 **Both-direction (sandwich) swap**: charged **3.6%** (`MAX_FEE`)
      - Effectively 1.8% on front-run, 1.8% on back-run.

- **Why it matters**: Sandwich bots often front-run and back-run swaps within a single block. This hook flags that pattern and makes it **expensive**, reducing MEV profits and deterring exploitative behavior.


### 4. `BlockPositionHook`

- **Goal**: Penalize transactions that appear **early in a block**, especially those sent by MEV bots attempting to front-run.

- **How it works**:
  - Tracks each transaction's **position in the current block**.
  - The first swap in a block pays the **maximum fee** (1.05%).
  - For each new unique `tx.origin` within the same block:
    - The fee is **reduced** by 50% relative to the last one (down to a minimum of 0.5%).
    - This creates an incentive for users to appear later in the block, and **disincentivizes frontrunning**.
  - If the same `tx.origin` appears multiple times (potential backrun), it is charged the **maximum fee** again.
  - Uses **transient storage** to distinguish between multiple calls in the same transaction vs different transactions.

- **Why it matters**: MEV bots typically try to be **first** in a block. This hook flips the incentive — making first-in-line trades **more expensive**, and rewarding users who aren't manipulating the block.


### 5. `DetoxerHook`
- **Goal**: Combine all the above hooks into a single, powerful hook to fight against MEV attacks.
  
- **Currently not implemented**


## Back Testing

- All hooks were backtested using Uniswap V3 data from a low-liquidity LAI-USDT pool  
- ~1,000 real historical transactions were processed:  
  - 900+ swaps  
  - 20+ liquidity events (adds/removes)  
- Included analysis of **20+ real sandwich attacks**

## Performance results (compared to vanilla pool)

- The initial testing results are available in the `data/reports/` directory.
  
### 1. 📈 InitialPriceRangeHook

| Category   | Avg. Fee Delta (Hook) | Vanilla Pool | Difference |
|------------|------------------------|---------------|------------|
| **total**     | 9,932                   | 10,000        | -68        |
| **attacker**  | 15,350                  | 10,000        | +5,350     |
| **victim**    | 5,333                   | 10,000        | -4,667     |
| **regular**   | 9,681                   | 10,000        | -319       |

💡 This shows the hook successfully increases fees for attackers while reducing the burden on victims and regular users.

### 2. ⚙️ DynamicPriorityFeeHook

| Category   | Avg. Fee Delta (Hook) | Vanilla Pool | Difference |
|------------|------------------------|---------------|------------|
| **total**     | 9,972                   | 10,000        | -28        |
| **attacker**  | 19,775                  | 10,000        | +9,775     |
| **victim**    | 6,817                   | 10,000        | -3,183     |
| **regular**   | 9,372                   | 10,000        | -628       |

💡 This hook heavily penalizes attackers while modestly reducing fees for victims and regular users.

### 3. 🔁 BothDirectionSwapHook

| Category   | Avg. Fee Delta (Hook) | Vanilla Pool | Difference |
|------------|------------------------|---------------|------------|
| **total**     | 10,035                  | 10,000        | +35        |
| **attacker**  | 24,750                  | 10,000        | +14,750    |
| **victim**    | 9,000                   | 10,000        | -1,000     |
| **regular**   | 9,031                   | 10,000        | -969       |

💡 This hook strongly penalizes attackers, while also slightly reducing fees for regular users and victims.

### 4. ⏱ BlockPositionHook

| Category   | Avg. Fee Delta (Hook) | Vanilla Pool | Difference |
|------------|------------------------|---------------|------------|
| **total**     | 10,012                  | 10,000        | +12        |
| **attacker**  | 10,408                  | 10,000        | +408       |
| **victim**    | 5,250                   | 10,000        | -4,750     |
| **regular**   | 10,118                  | 10,000        | +118       |

💡 This hook mildly increases fees for attackers and strongly reduces them for victims, while regular users see near-neutral impact.


## 🧪 How to Test Hooks with Different Settings

- **Adjust FEE values** inside the hook contracts located in `src/`
- Run the Foundry test suite:

  ```bash
  forge test -vv

- Check the results in `data/reports/` for each hook
  - Each hook generates a CSV file with the results of the test
  - The CSV files contain the swap count, total fee delta, and average fee delta for each type of swap participant


## 📊 How to Interpret Results

Each result file contains **4 rows**, representing different types of swap participants:

- **total** — All swaps included in the test  
- **attacker** — Swaps identified as part of sandwich attacks  
- **victim** — Swaps negatively affected by sandwich attacks  
- **regular** — Neutral users not involved in MEV activity

Each row includes **3 values**:

1. **Swap count** — Number of swaps in that category  
2. **Total fee delta** — Total additional fee paid (or saved) due to the hook  
3. **Average fee delta** — Average fee impact per swap

## Future Improvements

- Use `hookData` instead of `tx.origin` to identify user address more reliably  
- Tune fee percentage dynamically for each mitigation technique  
- Add new hooks to target other MEV patterns (e.g., front-running liquidity, back-running liquidity, txCount, etc.)
- Combine all techniques into a single, powerful **Detoxer Hook**  
- Enhance analytics: compute net profit breakdown per trade (for LP, attacker, victim, and regular user)  
- Integrate MEV data from Flashbots or similar services to improve detection and mitigation
- Integrate with other protocols (e.g., Brevis, ChainLink etc.) to have some off-chain data and improve the detection of MEV
- Collect HookFee and redistribute historicaly rewards to victims
