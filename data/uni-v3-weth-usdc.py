from dotenv import load_dotenv
import os
import requests
from web3 import Web3
import json

# Load environment variables
load_dotenv()

GRAPH_API_KEY = os.getenv("GRAPH_API_KEY")
UNI_V3_SUBGRAPH = os.getenv("UNI_V3_SUBGRAPH")

# Set up Uniswap V3 subgraph URL
GRAPHQL_URL = f"https://gateway.thegraph.com/api/{GRAPH_API_KEY}/subgraphs/id/{UNI_V3_SUBGRAPH}"

# Define the WETH-USDC pool address (WETH-USDC 0.05% pool on Uniswap V3)
POOL_ID = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640".lower()

USDC_DECIMALS = 6
WETH_DECIMALS = 18


def convert_bigdecimal(amount: str, decimals: int = 18):
    """Convert The Graph's BigDecimal (float) to uint256 format."""
    return int(float(amount) * (10 ** decimals))


# GraphQL query to fetch the last 100 swaps for the WETH-USDC pool
query = f"""
{{
  swaps(first: 1000, orderBy: timestamp, orderDirection: asc, where: {{ pool: "{POOL_ID}" }}) {{
    transaction {{
      id
      blockNumber
      timestamp
      gasUsed
      gasPrice
    }}
    timestamp
    sender
    recipient
    origin
    amount0
    amount1
    amountUSD
    sqrtPriceX96
    tick
    logIndex
  }}
  mints(first: 50, orderBy: timestamp, orderDirection: asc, where: {{ pool: "{POOL_ID}" }}) {{
    transaction {{
      id
      blockNumber
      timestamp
      gasUsed
      gasPrice
    }}
    timestamp
    owner
    sender
    origin
    tickLower
    tickUpper
    amount
    amount0
    amount1
    logIndex
  }}
  burns(first: 10, orderBy: timestamp, orderDirection: asc, where: {{ pool: "{POOL_ID}" }}) {{
    transaction {{
      id
      blockNumber
      timestamp
      gasUsed
      gasPrice
    }}
    timestamp
    owner
    origin
    tickLower
    tickUpper
    amount
    amount0
    amount1
    logIndex
  }}
}}
"""

response = requests.post(GRAPHQL_URL, json={"query": query})
data = response.json()["data"]

swaps, mints, burns, all = [], [], [], []

# Process swaps
for s in data["swaps"]:
    # invert sign for amounts (uni v3 uses opposite sign compared to uni v4)
    amount0 = -convert_bigdecimal(s["amount0"], USDC_DECIMALS)
    amount1 = -convert_bigdecimal(s["amount1"], WETH_DECIMALS)
    amountUSD = convert_bigdecimal(
        s["amountUSD"], USDC_DECIMALS)  # Use 6 as well

    swaps.append({
        "amount0": amount0,
        "amount1": amount1,
        "amountUSD": amountUSD,
        "sqrtPriceX96": int(s["sqrtPriceX96"]),
        "tick": int(s["tick"]),
        "blockNumber": int(s["transaction"]["blockNumber"]),
        "logIndex": int(s["logIndex"]),
    })

    all.append({
        "eventType": "swap",
        "origin": s["origin"],
        "txId": s["transaction"]["id"],
        "blockNumber": int(s["transaction"]["blockNumber"]),
        "timestamp": int(s["timestamp"]),
        "logIndex": int(s["logIndex"]),
        "gasUsed": int(s["transaction"]["gasUsed"]),
        "gasPrice": int(s["transaction"]["gasPrice"])
    })

# Process mints (liquidity added)
for m in data["mints"]:
    # use 18 decimals for USDC
    amount0 = convert_bigdecimal(m["amount0"], USDC_DECIMALS)
    amount1 = convert_bigdecimal(m["amount1"], WETH_DECIMALS)

    mints.append({
        "tickLower": int(m["tickLower"]),
        "tickUpper": int(m["tickUpper"]),
        "amount": int(m["amount"]),
        "amount0": amount0,
        "amount1": amount1,
        "blockNumber": int(m["transaction"]["blockNumber"]),
        "logIndex": int(m["logIndex"]),
    })

    all.append({
        "eventType": "mint",
        "origin": m["origin"],
        "txId": m["transaction"]["id"],
        "blockNumber": int(m["transaction"]["blockNumber"]),
        "timestamp": int(m["timestamp"]),
        "logIndex": int(m["logIndex"]),
        "gasUsed": int(m["transaction"]["gasUsed"]),
        "gasPrice": int(m["transaction"]["gasPrice"])
    })

# Process burns (liquidity removed)
for b in data["burns"]:
    amount0 = convert_bigdecimal(b["amount0"], USDC_DECIMALS)
    amount1 = convert_bigdecimal(b["amount1"], WETH_DECIMALS)

    burns.append({
        "tickLower": int(b["tickLower"]),
        "tickUpper": int(b["tickUpper"]),
        "amount": -int(b["amount"]),
        "amount0": amount0,
        "amount1": amount1,
        "blockNumber": int(b["transaction"]["blockNumber"]),
        "logIndex": int(b["logIndex"]),
    })

    all.append({
        "eventType": "burn",
        "origin": b["origin"],
        "txId": b["transaction"]["id"],
        "blockNumber": int(b["transaction"]["blockNumber"]),
        "timestamp": int(b["timestamp"]),
        "logIndex": int(b["logIndex"]),
        "gasUsed": int(b["transaction"]["gasUsed"]),
        "gasPrice": int(b["transaction"]["gasPrice"])
    })


# Save for Foundry test

all.sort(key=lambda x: (x["blockNumber"], x["logIndex"]))
swaps.sort(key=lambda x: (x["blockNumber"], x["logIndex"]))
mints.sort(key=lambda x: (x["blockNumber"], x["logIndex"]))
burns.sort(key=lambda x: (x["blockNumber"], x["logIndex"]))

with open("data/all.json", "w") as f:
    json.dump(all, f, indent=4)

with open("data/swaps.json", "w") as f:
    json.dump(swaps, f, indent=4)

with open("data/mints.json", "w") as f:
    json.dump(mints, f, indent=4)

with open("data/burns.json", "w") as f:
    json.dump(burns, f, indent=4)

print("✅ Events saved!")
