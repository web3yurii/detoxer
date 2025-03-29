from collections import defaultdict
import json

# Load the file
with open("data/graph/events.json") as f:
    events = json.load(f)

block_counts = defaultdict(int)
origin_counts = defaultdict(int)
for event in events:
    block_counts[event["blockNumber"]] += 1
    origin_counts[event["origin"]] += 1

# distinct by block and origin
block_and_origin_counts = defaultdict(int)
for event in events:
    e = f"{event['blockNumber']} {event['origin']}"
    block_and_origin_counts[e] += 1

# Filter blocks with 3+ swaps
busy_blocks = {b: c for b, c in block_counts.items() if c >= 3}
busy_origins = {o: c for o, c in origin_counts.items() if c >= 2}
busy_blocks_origins = {k: v for k, v in block_and_origin_counts.items() if v >= 2}
print("Sorted by timestamp")
print(json.dumps(busy_blocks, indent=2))
print()
print(json.dumps(busy_origins, indent=2))
print()
print(json.dumps(busy_blocks_origins, indent=2))
print()

# sort descending
busy_blocks = dict(sorted(busy_blocks.items(), key=lambda item: item[1], reverse=True))
busy_origins = dict(sorted(busy_origins.items(), key=lambda item: item[1], reverse=True))
busy_blocks_origins = dict(sorted(busy_blocks_origins.items(), key=lambda item: item[1], reverse=True))

print("Sroted by count")
print(json.dumps(busy_blocks, indent=2))
print()
print(json.dumps(busy_origins, indent=2))
print()
print(json.dumps(busy_blocks_origins, indent=2))

