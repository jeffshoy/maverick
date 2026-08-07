import json
import subprocess
import sys

profile = sys.argv[1]
region = sys.argv[2]
json_path = sys.argv[3]

with open(json_path) as f:
    names = json.load(f)

print(f"Total parameters to delete: {len(names)}")

for i in range(0, len(names), 10):
    batch = names[i:i+10]
    cmd = ["aws", "ssm", "delete-parameters", "--profile", profile, "--region", region, "--names"] + batch
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"BATCH {i//10+1} FAILED: {result.stderr}")
        sys.exit(1)
    out = json.loads(result.stdout)
    print(f"Batch {i//10+1}: deleted {len(out.get('DeletedParameters', []))}, invalid {out.get('InvalidParameters', [])}")

print("Done.")
