import json

# Load your JSON data
with open('data/graph/events.json', 'r') as f:
    data = json.load(f)

# Track total priority fee and count
total_priority_fee = 0
count = 0

for tx in data:
    gas_price = tx.get("gasPrice")
    base_fee = tx.get("blockBaseFeePerGas")
    print(f"gasPrice: {gas_price}, baseFee: {base_fee}")

    if gas_price is not None and base_fee is not None:
        priority_fee = gas_price - base_fee
        total_priority_fee += priority_fee
        count += 1

# Compute average
average_priority_fee = total_priority_fee / count if count > 0 else 0

print(f"Processed {count} transactions")
print(f"Average priority fee: {average_priority_fee} wei")
