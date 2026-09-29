"""Versioned consumer/observer boundary; outcome records never enter model evidence."""
from __future__ import annotations

import hashlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

from contracts import ContractError, ROOT, finite, load_json, timestamp, validate_bundle


def validate(value: Any, name: str) -> None:
    finite(value)
    schemas = [load_json(path) for path in (ROOT / "schemas").glob("*.schema.json")]
    registry = Registry().with_resources((s["$id"], Resource.from_contents(s)) for s in schemas)
    selected = load_json(ROOT / "schemas" / (name + ".schema.json"))
    error = next(Draft202012Validator(selected, registry=registry, format_checker=FormatChecker()).iter_errors(value), None)
    if error:
        raise ContractError("OBSERVER_SCHEMA_" + name.upper() + "_" + error.validator.upper())


def file_hash(path: str | Path) -> str:
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_config(config: dict[str, Any]) -> None:
    validate(config, "observer-config")
    for key in ("stateRoot",):
        if not Path(config[key]).is_absolute():
            raise ContractError("OBSERVER_ABSOLUTE_PATH_REQUIRED")
    for name in ("script", "config"):
        path = Path(config["collector"][name + "Path"])
        if not path.is_absolute() or not path.is_file() or path.is_symlink():
            raise ContractError("TRUSTED_COLLECTOR_FILE_REQUIRED")
        if file_hash(path) != config["collector"][name + "Sha256"]:
            raise ContractError("COLLECTOR_HASH_MISMATCH")
    evaluation = config["evaluation"]
    mode = evaluation["mode"]
    if mode == "collection-only" and any(evaluation[key] is not None for key in ("model", "fixturePath", "runtimePath")):
        raise ContractError("COLLECTION_ONLY_CANNOT_CONFIGURE_MODEL")
    if mode == "offline" and (evaluation["model"] != "fixture-v1" or not evaluation["fixturePath"] or evaluation["runtimePath"]):
        raise ContractError("OBSERVER_OFFLINE_REQUIRES_FIXTURES")
    if mode == "live" and (not evaluation["model"] or evaluation["model"] in ("auto", "default")
                           or not evaluation["runtimePath"] or evaluation["fixturePath"]):
        raise ContractError("OBSERVER_LIVE_REQUIRES_EXPLICIT_RUNTIME_MODEL")


def validate_page(page: dict[str, Any], request: dict[str, Any]) -> None:
    validate(request, "observation-request")
    validate(page, "observation-page")
    if any(page[key] != request[key] for key in ("studyId", "captureId")) or page["page"]["cursor"] != request["cursor"]:
        raise ContractError("CAPTURE_REQUEST_BINDING_MISMATCH")
    start, end = (timestamp(page["window"][key]) for key in ("startedAt", "completedAt"))
    if start < timestamp(request["startedAt"]) or end < start:
        raise ContractError("CAPTURE_WINDOW_INVALID")
    if end > datetime.now(timezone.utc):
        raise ContractError("CAPTURE_WINDOW_IN_FUTURE")
    if page["page"]["complete"] != (page["page"]["nextCursor"] is None):
        raise ContractError("CAPTURE_PAGINATION_INVALID")
    if len(page["inventory"]) > request["maxItems"] or len(page["snapshots"]) > request["maxItems"]:
        raise ContractError("CAPTURE_PAGE_LIMIT_EXCEEDED")
    ids = [item["familyId"] for item in page["inventory"]]
    if len(ids) != len(set(ids)):
        raise ContractError("DUPLICATE_INVENTORY_FAMILY")
    if request.get("purpose", "INVENTORY") == "REFRESH":
        target = request["trackedPullRequests"][0]
        if not page["page"]["complete"]:
            raise ContractError("REFRESH_MUST_BE_TERMINAL")
        if any(item["familyId"] != target["familyId"] or item["pullRequestId"] != target["pullRequestId"]
               for item in page["inventory"]) or any(item["familyId"] != target["familyId"] for item in page["outcomes"]):
            raise ContractError("REFRESH_FAMILY_MISMATCH")
    snapshot_ids = [item["bundle"]["familyId"] for item in page["snapshots"]]
    if len(snapshot_ids) != len(set(snapshot_ids)):
        raise ContractError("DUPLICATE_SNAPSHOT_FAMILY")
    for snapshot in page["snapshots"]:
        bundle, observation = snapshot["bundle"], snapshot["observation"]
        validate_bundle(bundle)
        if bundle["label"] is not None or bundle["cohort"] == "HISTORICAL":
            raise ContractError("PROSPECTIVE_CAPTURE_FORBIDS_LABELS_AND_HISTORICAL_COHORT")
        if not start <= timestamp(observation["capturedAt"]) <= end:
            raise ContractError("SNAPSHOT_OUTSIDE_CAPTURE_WINDOW")
        if request.get("purpose") == "REFRESH" and timestamp(bundle["provenance"]["cutoff"]) < timestamp(request["startedAt"]):
            raise ContractError("REFRESH_REQUIRES_CURRENT_CAPTURE")
        if timestamp(bundle["provenance"]["cutoff"]) > timestamp(observation["capturedAt"]):
            raise ContractError("SNAPSHOT_CUTOFF_AFTER_CAPTURE")
        if timestamp(bundle["provenance"]["exportedAt"]) > end:
            raise ContractError("BUNDLE_EXPORTED_AFTER_CAPTURE_WINDOW")
        if bundle["familyId"] not in ids:
            raise ContractError("SNAPSHOT_NOT_IN_INVENTORY")
        inventory = next(item for item in page["inventory"] if item["familyId"] == bundle["familyId"])
        for field in ("pullRequestId", "sourceCommit", "targetCommit", "targetRef"):
            if inventory[field] != bundle["provenance"][field]:
                raise ContractError("INVENTORY_SNAPSHOT_BINDING_MISMATCH")
        if inventory["state"] != observation["state"]:
            raise ContractError("INVENTORY_STATE_MISMATCH")
    for outcome in page["outcomes"]:
        captured = timestamp(outcome["capturedAt"])
        if not start <= captured <= end or (outcome["occurredAt"] and timestamp(outcome["occurredAt"]) > captured):
            raise ContractError("OUTCOME_CAPTURE_TIME_INVALID")
        if outcome["kind"].startswith("ADJUDICATED"):
            raise ContractError("ADJUDICATION_REQUIRES_SEPARATE_OPERATOR_IMPORT")
