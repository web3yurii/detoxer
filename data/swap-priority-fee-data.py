from dotenv import load_dotenv
import os
import requests
from web3 import Web3

load_dotenv()

GRAPH_API_KEY = os.getenv("GRAPH_API_KEY")
INFURA_API_KEY = os.getenv("INFURA_API_KEY")
UNI_V3_SUBGRAPH = os.getenv("UNI_V3_SUBGRAPH")

# Set up Uniswap V3 subgraph URL
GRAPHQL_URL = f"https://gateway.thegraph.com/api/{GRAPH_API_KEY}/subgraphs/id/{UNI_V3_SUBGRAPH}"

# Query latest 10 swaps
query = """
{
  swaps(first: 10, orderBy: timestamp, orderDirection: desc) {
    transaction {
      id
    }
  }
}
"""
response = requests.post(GRAPHQL_URL, json={"query": query})
swaps = response.json()["data"]["swaps"]
tx_hashes = [swap["transaction"]["id"] for swap in swaps]

print(f"Latest 10 swaps: {tx_hashes}")

# Set up Ethereum RPC connection (Infura, Alchemy, etc.)
RPC_URL = f"https://mainnet.infura.io/v3/{INFURA_API_KEY}"
web3 = Web3(Web3.HTTPProvider(RPC_URL))

priority_fees = []

for tx_hash in tx_hashes:
    tx = web3.eth.get_transaction(tx_hash)

    # If EIP-1559 transaction
    if "maxPriorityFeePerGas" in tx:
        print("Block", tx["blockNumber"])
        print("maxPriorityFeePerGas", tx["maxPriorityFeePerGas"])
        print("maxFeePerGas", tx["maxFeePerGas"])
        print("gasPrice", tx["gasPrice"])
        print()
        priority_fees.append(web3.from_wei(tx["maxPriorityFeePerGas"], "gwei"))
    else:  # Legacy transaction, estimate using gasPrice - baseFee
        block = web3.eth.get_block(tx["blockNumber"])
        base_fee = block.get("baseFeePerGas", 0)
        priority_fee = tx["gasPrice"] - base_fee
        print("legacy ", priority_fee)
        priority_fees.append(web3.from_wei(priority_fee, "gwei"))

# Compute the average priority fee
average_priority_fee = sum(priority_fees) / len(priority_fees)
print(f"Average Priority Fee for last 10 swaps: {average_priority_fee} Gwei")
