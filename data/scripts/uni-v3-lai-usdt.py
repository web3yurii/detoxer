from dotenv import load_dotenv
import os
import requests
from web3 import Web3
import json

# Load environment variables
load_dotenv()

GRAPH_API_KEY = os.getenv("GRAPH_API_KEY")
UNI_V3_SUBGRAPH = os.getenv("UNI_V3_SUBGRAPH")
INFURA_API_KEY = os.getenv("INFURA_API_KEY")
INFURA_URL = f"https://mainnet.infura.io/v3/{INFURA_API_KEY}"

# Set up Uniswap V3 subgraph URL
GRAPHQL_URL = f"https://gateway.thegraph.com/api/{GRAPH_API_KEY}/subgraphs/id/{UNI_V3_SUBGRAPH}"
web3 = Web3(Web3.HTTPProvider(INFURA_URL))


# Define the LAI-USDT pool address
POOL_ID = "0xc0b7f8b3f857df57027d340cf101a164c3b20bb8".lower()


def convert_bigdecimal(amount: str, decimals: int = 18):
    """Convert The Graph's BigDecimal (float) to uint256 format."""
    return int(float(amount) * (10 ** decimals))


# GraphQL query to fetch the last 1000 swaps, 50 mints, and 20 burns for the LAI-USDT pool
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
  burns(first: 20, orderBy: timestamp, orderDirection: asc, where: {{ pool: "{POOL_ID}" }}) {{
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

print("Swap length:", len(data["swaps"]))
print("Mint length:", len(data["mints"]))
print("Burn length:", len(data["burns"]))

events = []

with open('data/graph/block_info.json', 'r') as f:
    block_info = json.load(f)

with open('data/graph/sandwich.json', 'r') as f:
    sandwich = json.load(f)

# Process swaps
for s in data["swaps"]:
    # invert sign for amounts (uni v3 uses opposite sign compared to uni v4)
    amount0 = -convert_bigdecimal(s["amount0"])
    amount1 = -convert_bigdecimal(s["amount1"], 6)
    amountUSD = convert_bigdecimal(s["amountUSD"], 6)

    block_number = int(s["transaction"]["blockNumber"])
    if block_number not in block_info:
        block_info[block_number] = web3.eth.get_block(block_number).baseFeePerGas

    txId = s["transaction"]["id"]

    events.append({
        "sandwich": sandwich.get(f"{txId} {s['eventType']}", 0),
        "eventType": "swap",
        "origin": s["origin"],
        "txId": txId,
        "blockNumber": block_number,
        "blockBaseFeePerGas": int(block_info[block_number]),
        "timestamp": int(s["timestamp"]),
        "logIndex": int(s["logIndex"]),
        "gasUsed": int(s["transaction"]["gasUsed"]),
        "gasPrice": int(s["transaction"]["gasPrice"]),
        "amount0": amount0,
        "amount1": amount1,
        "amount": amount1 < 0 and -amountUSD or amountUSD,
        "sqrtPriceX96": int(s["sqrtPriceX96"]),
        "tick": int(s["tick"]),
        "tickLower": 0,
        "tickUpper": 0,
    })

# Process mints (liquidity added)
for m in data["mints"]:
    amount0 = convert_bigdecimal(m["amount0"])
    amount1 = convert_bigdecimal(m["amount1"], 6)

    block_number = int(m["transaction"]["blockNumber"])
    if block_number not in block_info:
        block_info[block_number] = web3.eth.get_block(block_number).baseFeePerGas

    txId = m["transaction"]["id"]

    events.append({
        "sandwich": sandwich.get(f"{txId} {m['eventType']}", 0),
        "eventType": "liquidity",
        "origin": m["origin"],
        "txId": txId,
        "blockNumber": block_number,
        "blockBaseFeePerGas": int(block_info[block_number]),
        "timestamp": int(m["timestamp"]),
        "logIndex": int(m["logIndex"]),
        "gasUsed": int(m["transaction"]["gasUsed"]),
        "gasPrice": int(m["transaction"]["gasPrice"]),
        "amount": int(m["amount"]),
        "amount0": amount0,
        "amount1": amount1,
        "sqrtPriceX96": 0,
        "tick": 0,
        "tickLower": int(m["tickLower"]),
        "tickUpper": int(m["tickUpper"]),
    })

# Process burns (liquidity removed)
for b in data["burns"]:
    amount0 = convert_bigdecimal(b["amount0"])
    amount1 = convert_bigdecimal(b["amount1"], 6)

    block_number = int(b["transaction"]["blockNumber"])
    if block_number not in block_info:
        block_info[block_number] = web3.eth.get_block(block_number).baseFeePerGas

    txId = b["transaction"]["id"]

    events.append({
        "sandwich": sandwich.get(f"{txId} {b['eventType']}", 0),
        "eventType": "liquidity",
        "origin": b["origin"],
        "txId": txId,
        "blockNumber": block_number,
        "blockBaseFeePerGas": int(block_info[block_number]),
        "timestamp": int(b["timestamp"]),
        "logIndex": int(b["logIndex"]),
        "gasUsed": int(b["transaction"]["gasUsed"]),
        "gasPrice": int(b["transaction"]["gasPrice"]),
        "amount": -int(b["amount"]),
        "amount0": amount0,
        "amount1": amount1,
        "sqrtPriceX96": 0,
        "tick": 0,
        "tickLower": int(b["tickLower"]),
        "tickUpper": int(b["tickUpper"])
    })

# Print size

print(f"Events: {len(events)}")

# Save for Foundry test

events.sort(key=lambda x: (x["blockNumber"], x["logIndex"]))

with open("data/graph/events.json", "w") as f:
    json.dump(events, f, indent=4)

with open("data/graph/block_info.json", "w") as f:
    json.dump(block_info, f, indent=4)

print("✅ Events saved!")

# sandwich info:
# 0 - no sandwich
# 1 - front running
# 2 -
# 3 -
# 4 -
# 5 - victim swap
# 6 -
# 7 - 
# 8 -
# 9 - back running
