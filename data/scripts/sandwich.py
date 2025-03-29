import json

# Load the JSON data
with open('data/graph/events.json', 'r') as f:
    data = json.load(f)

# Build a dictionary of { txId: sandwich } where sandwich != 0
sandwich_txs = {
    f"{entry['txId']} {entry['eventType']}": entry['sandwich']
    for entry in data
    if entry.get('sandwich', 0) != 0
}

# Save to file (optional)
with open('data/graph/sandwich.json', 'w') as out:
    json.dump(sandwich_txs, out, indent=2)

# Print for quick check
print(f"Found {len(sandwich_txs)} sandwich txs:")
