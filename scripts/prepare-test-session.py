#!/usr/bin/env python3
"""Copy an xctestrun beside its products and isolate the RAMnotes unit-test host."""
import argparse
from pathlib import Path
import plistlib
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
args = parser.parse_args()
source = args.source.resolve()
with source.open("rb") as stream:
    data = plistlib.load(stream)

if "TestConfigurations" in data:
    targets = [target for config in data["TestConfigurations"] for target in config["TestTargets"]]
else:
    targets = [value for value in data.values() if isinstance(value, dict)]
hosted = [target for target in targets
          if target.get("IsAppHostedTestBundle")
          and target.get("TestHostBundleIdentifier") == "com.ramnotes.RAMnotes"]
if not hosted:
    parser.error("The xctestrun has no RAMnotes unit-test host.")
session = str(uuid.uuid4())
for target in hosted:
    target["CommandLineArguments"] = ["--test-session", session]
# Keep __TESTROOT__ paths valid by writing beside the original xctestrun.
destination = source.with_name(f"ramnotes-session-{session}.xctestrun")
with destination.open("wb") as stream:
    plistlib.dump(data, stream)
print(destination)
