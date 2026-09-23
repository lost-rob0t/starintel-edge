#!/usr/bin/env python3
"""Validate local target/ownership metadata; does not certify any device."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def check_catalog() -> int:
    catalog = json.loads((ROOT / "contracts/targets.jsonld").read_text())
    assert catalog["canonicalSource"] == "https://github.com/lost-rob0t/starintel-edge"
    assert catalog["contractVersion"] == 1
    assert catalog["@type"] == "TargetCatalog"
    targets = catalog["targets"]
    ids = [target["id"] for target in targets]
    assert len(ids) == len(set(ids)), "Duplicate target ID"
    assert {"rpi", "android", "wearos", "android-glasses", "xreal", "viture", "vuzix-realwear", "meta"} <= set(ids)
    for target in targets:
        path = (ROOT / target["path"]).resolve()
        assert path.is_relative_to(ROOT), "Target path escapes repository"
        assert path.is_dir() and (path / "README.md").is_file()
        assert target["execution"] in {"native", "companion"}
        assert target["status"] == "scaffold", "Update validator with real device evidence before promoting support"
        assert target["backend"] and target["gates"]
        assert len(target["gates"]) == len(set(target["gates"]))
    meta = next(target for target in targets if target["id"] == "meta")
    assert meta["execution"] == "companion"
    assert "physical-device" in meta["gates"]
    assert (ROOT / "runtime/starintel-edge.asd").is_file()
    assert (ROOT / "docs/ADR-0001-canonical-upstream.md").is_file()
    assert (ROOT / "downstream/README.md").is_file()
    return len(targets)

if __name__ == "__main__":
    print(f"Validated {check_catalog()} scaffold target contracts; no hardware support implied.")
