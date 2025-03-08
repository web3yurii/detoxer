from dotenv import load_dotenv
import os
import requests
from web3 import Web3

# Load environment variables
load_dotenv()

GRAPH_API_KEY = os.getenv("GRAPH_API_KEY")
INFURA_API_KEY = os.getenv("INFURA_API_KEY")
UNI_V3_SUBGRAPH = os.getenv("UNI_V3_SUBGRAPH")

# Set up Uniswap V3 subgraph URL
GRAPHQL_URL = f"https://gateway.thegraph.com/api/{GRAPH_API_KEY}/subgraphs/id/{UNI_V3_SUBGRAPH}"

# Define the WETH-USDC pool address (WETH-USDC 0.05% pool on Uniswap V3)
POOL_ID = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640".lower()

# GraphQL query to fetch the last 100 swaps for the WETH-USDC pool
query = f"""
{{
  swaps(first: 20, orderBy: timestamp, orderDirection: desc, where: {{ pool: "{POOL_ID}" }}) {{
    amount0
    amount1
    token0 {{
      symbol
    }}
    token1 {{
      symbol
    }}
    transaction {{
      id
    }}
  }}
}}
"""

response = requests.post(GRAPHQL_URL, json={"query": query})
swaps = response.json()["data"]["swaps"]

# Extracting all USDC swap amounts (handling both directions)
usdc_swaps = []
for swap in swaps:
    token0 = swap["token0"]["symbol"]
    token1 = swap["token1"]["symbol"]
    amount0 = float(swap["amount0"])
    amount1 = float(swap["amount1"])

    print(f"Swapped {amount0} {token0} for {amount1} {token1}")

    # If USDC is token0 and user is buying WETH, they are spending USDC
    if token0 == "USDC":
        usdc_swaps.append(abs(amount0))
    
    # If USDC is token1 and user is selling WETH, they are receiving USDC
    elif token1 == "USDC":
        usdc_swaps.append(abs(amount1))

# Compute the average USDC swapped
average_usdc_swapped = sum(usdc_swaps) / len(usdc_swaps) if usdc_swaps else 0

print(f"Average USDC swapped in last {len(usdc_swaps)} swaps for WETH-USDC pool: {average_usdc_swapped:.2f} USDC")