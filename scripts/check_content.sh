#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
import math
from collections import Counter
from pathlib import Path

root = Path("godot/data")
expected = {
    "activities.json": 43,
    "events.json": 26,
    "items.json": 21,
    "careers.json": 38,
}

loaded = {}
for name, count in expected.items():
    path = root / name
    if not path.is_file():
        raise SystemExit(f"missing content file: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    rows = value if isinstance(value, list) else value.get("items", value.get("entries", []))
    if len(rows) != count:
        raise SystemExit(f"{name}: expected {count}, got {len(rows)}")
    ids = [row.get("id") for row in rows]
    if None in ids or len(ids) != len(set(ids)):
        raise SystemExit(f"{name}: missing or duplicate id")
    loaded[name] = rows

kinds = Counter(row["kind"] for row in loaded["activities.json"])
required_kinds = {"education": 15, "job": 11, "rest": 4, "adventure": 5, "challenge": 8}
if dict(kinds) != required_kinds:
    raise SystemExit(f"activity kind mismatch: {dict(kinds)}")

activity_fields = {
    "id", "kind", "name", "description", "durationSlots", "baseCost", "baseReward",
    "energyDelta", "stressDelta", "risk", "primaryStat", "gains", "fixedDeltas",
    "requires", "tags",
}
for row in loaded["activities.json"]:
    missing = activity_fields - row.keys()
    if missing:
        raise SystemExit(f"{row['id']}: missing activity fields {sorted(missing)}")
    if not 1 <= row["durationSlots"] <= 6:
        raise SystemExit(f"{row['id']}: durationSlots out of range")
    if not 0 <= row["risk"] <= 1:
        raise SystemExit(f"{row['id']}: risk out of range")
    if not -40 <= row["energyDelta"] <= 100 or not -100 <= row["stressDelta"] <= 30:
        raise SystemExit(f"{row['id']}: meter delta out of range")
    if row["kind"] == "adventure":
        for field in ("nodes", "enemyPool", "lootTable"):
            if field not in row:
                raise SystemExit(f"{row['id']}: missing adventure field {field}")
        if row["nodes"] != 3 or not row["enemyPool"] or not row["lootTable"]:
            raise SystemExit(f"{row['id']}: invalid three-node adventure contract")
    if row["kind"] == "challenge":
        for field in ("challengeWeights", "baseDifficulty", "rewardTable"):
            if field not in row:
                raise SystemExit(f"{row['id']}: missing challenge field {field}")
        if not row["challengeWeights"] or row["baseDifficulty"] <= 0 or not row["rewardTable"]:
            raise SystemExit(f"{row['id']}: invalid challenge contract")

event_fields = {"id", "type", "once", "priority", "weight", "trigger", "choices", "defaultChoice", "cooldownSlots"}
allowed_effect_groups = {"stats", "meters", "bigValues", "relations", "flags"}
for row in loaded["events.json"]:
    missing = event_fields - row.keys()
    if missing:
        raise SystemExit(f"{row['id']}: missing event fields {sorted(missing)}")
    choice_ids = [choice.get("id") for choice in row["choices"]]
    if not choice_ids or row["defaultChoice"] not in choice_ids or len(choice_ids) != len(set(choice_ids)):
        raise SystemExit(f"{row['id']}: invalid choices/defaultChoice")
    for choice in row["choices"]:
        effects = choice.get("effects", {})
        if set(effects) != allowed_effect_groups:
            raise SystemExit(f"{row['id']}/{choice['id']}: effect groups must be explicit and complete")

item_fields = {"id", "name", "category", "basePrice", "stackable", "equipSlot", "modifiers", "useEffects", "tags"}
equipment_categories = {"outfit", "accessory", "weapon", "armor"}
for row in loaded["items.json"]:
    missing = item_fields - row.keys()
    if missing:
        raise SystemExit(f"{row['id']}: missing item fields {sorted(missing)}")
    is_equipment = row["category"] in equipment_categories
    if is_equipment == bool(row["stackable"]):
        raise SystemExit(f"{row['id']}: equipment must not stack and consumables must stack")
    if is_equipment and row["equipSlot"] not in equipment_categories:
        raise SystemExit(f"{row['id']}: invalid equipment slot")

career_fields = {"id", "name", "category", "weights", "gate", "baseRenown", "description"}
for row in loaded["careers.json"]:
    missing = career_fields - row.keys()
    if missing or not row["weights"] or not row["gate"] or row["baseRenown"] <= 0:
        raise SystemExit(f"{row['id']}: invalid career contract, missing={sorted(missing)}")

for name in ("config.json", "profiles.json", "procedural.json"):
    path = root / name
    if not path.is_file():
        raise SystemExit(f"missing content file: {path}")
    json.loads(path.read_text(encoding="utf-8"))

profiles = json.loads((root / "profiles.json").read_text(encoding="utf-8"))
expected_profiles = {"balanced", "martial", "scholar", "artist", "leader", "care", "explorer", "prosperity"}
if {row.get("id") for row in profiles} != expected_profiles:
    raise SystemExit("growth profile ids do not match the eight-preset contract")
for row in profiles:
    total = sum(max(0.0, float(value)) for value in row.get("weights", {}).values())
    if not math.isclose(total, 1.0, rel_tol=0.0, abs_tol=1e-9):
        raise SystemExit(f"{row['id']}: profile weights total {total}, expected 1.0")

config = json.loads((root / "config.json").read_text(encoding="utf-8"))
expected_constants = {
    "schemaVersion": 2,
    "onlineSecondsPerSlot": 5,
    "offlineSecondsPerSlot": 60,
    "offlineCapSeconds": 28800,
    "slotsPerSeason": 28,
    "seasonsPerYear": 4,
    "inventoryStackMax": 99,
    "sellRatio": 0.5,
    "recentActivityWindow": 8,
    "eventInboxMax": 20,
    "generatedContractCount": 3,
    "generatedRivalCount": 5,
}
for key, expected_value in expected_constants.items():
    if config.get(key) != expected_value:
        raise SystemExit(f"config {key}: expected {expected_value}, got {config.get(key)}")

challenge_ids = {row["id"] for row in loaded["activities.json"] if row["kind"] == "challenge"}
challenge_schedule = config.get("challengeScheduleSlots", {})
if set(challenge_schedule) != challenge_ids:
    raise SystemExit("challengeScheduleSlots must cover all and only the eight challenges")
scheduled_slots = [int(value) for value in challenge_schedule.values()]
if len(scheduled_slots) != len(set(scheduled_slots)) or any(value < 1 or value > config["slotsPerSeason"] for value in scheduled_slots):
    raise SystemExit("challenge schedule slots must be unique and within one season")
for row in loaded["activities.json"]:
    if row["kind"] == "challenge" and "scheduled" not in row["tags"]:
        raise SystemExit(f"{row['id']}: scheduled challenge tag missing")

procedural = json.loads((root / "procedural.json").read_text(encoding="utf-8"))
for key, minimum in (("prefixes", 12), ("fields", 8), ("goals", 10)):
    if len(procedural.get(key, [])) < minimum:
        raise SystemExit(f"procedural {key}: expected at least {minimum}")

print("Content contract passed: activities=43 events=26 items=21 careers=38")
PY
