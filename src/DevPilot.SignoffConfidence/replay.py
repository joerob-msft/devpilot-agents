"""Deterministic read-only policy, replay persistence, and stratified accounting."""

from __future__ import annotations

import asyncio
from contextlib import contextmanager
import importlib.metadata
import os
from pathlib import Path
import platform
import stat
import tempfile
from typing import Any, Protocol

from contracts import (
    ContractError, MIN_MODEL_SUPPORT, RECOMMENDATIONS, ROOT, canonical, digest, load_json, make_prompt,
    parse_json, validate_assessment, validate_bundle, validate_result,
)


class AssessmentFailure(RuntimeError):
    pass


class CapabilityError(RuntimeError):
    pass


class Cancelled(RuntimeError):
    pass


class Provider(Protocol):
    metadata: dict[str, Any]

    async def assess(self, bundle: dict[str, Any], prompt: str, run: int) -> dict[str, Any]: ...


class FixtureProvider:
    def __init__(self, fixtures: dict[str, Any], bundles: list[dict[str, Any]], model: str):
        if model != "fixture-v1":
            raise ContractError("OFFLINE_MODEL_MUST_BE_fixture-v1")
        if (
            not isinstance(fixtures, dict)
            or set(fixtures) != {"schemaVersion", "cases"}
            or type(fixtures["schemaVersion"]) is not int
            or fixtures["schemaVersion"] != 1
            or not isinstance(fixtures["cases"], dict)
            or set(fixtures["cases"]) != {b["caseId"] for b in bundles}
        ):
            raise ContractError("FIXTURE_CASE_INVENTORY_MISMATCH")
        for bundle in bundles:
            if bundle["cohort"] != "SYNTHETIC" or bundle["provenance"]["provider"] != "FIXTURE":
                raise ContractError("OFFLINE_FIXTURES_REQUIRE_SYNTHETIC_CASES")
            answers = fixtures["cases"][bundle["caseId"]]
            if not isinstance(answers, list) or len(answers) != 2:
                raise ContractError("FIXTURE_REQUIRES_TWO_INDEPENDENT_RESPONSES")
        self.fixtures = fixtures
        self.metadata = {"provider": "fixture", "model": model, "sdk": None, "runtime": None}

    async def assess(self, bundle: dict[str, Any], prompt: str, run: int) -> dict[str, Any]:
        answer = self.fixtures["cases"][bundle["caseId"]][run]
        text = answer if isinstance(answer, str) else canonical(answer)
        return {"text": text, "usage": None, "model": "fixture-v1"}


def blocker(code: str, refs: list[str], reason: str) -> dict[str, Any]:
    return {"code": code, "evidenceRefs": refs, "reason": reason}


def prechecks(bundle: dict[str, Any], *, prospective: bool = False) -> list[dict[str, Any]]:
    result = []
    if any(not guidance["approved"] for guidance in bundle["guidance"]):
        result.append(blocker("GUIDANCE_NOT_APPROVED", [], "Operator-approved guidance is required."))
    for item in bundle["completeness"]:
        if item["status"] != "COMPLETE":
            result.append(blocker("INCOMPLETE_" + item["category"], item["evidenceRefs"], item["reason"]))
    for item in bundle["evidence"]:
        if item["kind"] == "CODE_CHECK" and item["status"] == "FAIL":
            result.append(blocker("DETERMINISTIC_CODE_FAILURE", [item["id"]], "Snapshot-bound code check failed."))
        elif item["kind"] in ("CODE_CHECK", "POLICY") and item["status"] != "PASS":
            result.append(blocker("REQUIRED_STATUS_UNKNOWN", [item["id"]], "Required policy/validation is not proven passing."))
    if bundle["reconstruction"]["status"] != "EXACT" and not prospective:
        result.append(blocker("HISTORICAL_RECONSTRUCTION_UNSUPPORTED", [], bundle["reconstruction"]["reason"]))
    if bundle["provenance"]["iteration"] is None:
        result.append(blocker("ITERATION_UNKNOWN", [], "Snapshot iteration is unavailable."))
    return result


def is_cancelled(cancel_file: Path | None) -> None:
    if cancel_file is not None and cancel_file.exists():
        raise Cancelled("CANCELLED")


async def bounded_assess(provider: Provider, bundle: dict[str, Any], prompt: str, run: int,
                         deadline: float, cancel_file: Path | None) -> dict[str, Any]:
    async def wait_cancel() -> None:
        while True:
            is_cancelled(cancel_file)
            await asyncio.sleep(0.05)

    task = asyncio.create_task(provider.assess(bundle, prompt, run))
    watcher = asyncio.create_task(wait_cancel())
    try:
        async with asyncio.timeout(deadline):
            done, _ = await asyncio.wait((task, watcher), return_when=asyncio.FIRST_COMPLETED)
            if watcher in done:
                await watcher
            return await task
    finally:
        for pending in (task, watcher):
            if not pending.done():
                pending.cancel()
        outcomes = await asyncio.gather(task, watcher, return_exceptions=True)
        # Cancellation can reveal failed runtime teardown. Never erase it behind a timeout.
        for outcome in outcomes:
            if isinstance(outcome, CapabilityError):
                raise outcome


async def evaluate(bundle: dict[str, Any], provider: Provider, deadline: int, max_attempts: int,
                   exploratory: bool = False, cancel_file: Path | None = None,
                   *, prospective: bool = False) -> dict[str, Any]:
    validate_bundle(bundle)
    is_cancelled(cancel_file)
    blockers = prechecks(bundle, prospective=prospective)
    failed_check = any(item["code"] == "DETERMINISTIC_CODE_FAILURE" for item in blockers)
    completeness = {item["category"]: item["status"] for item in bundle["completeness"]}
    can_describe = exploratory and all(completeness[x] == "COMPLETE" for x in ("CODE", "INTENT"))
    can_describe = can_describe and all(g["approved"] for g in bundle["guidance"])
    result: dict[str, Any] = {
        "schemaVersion": 1, "caseId": bundle["caseId"], "familyId": bundle["familyId"],
        "cohort": bundle["cohort"], "provenance": bundle["provenance"],
        "reconstruction": bundle["reconstruction"], "completeness": bundle["completeness"],
        "inputFingerprint": digest(bundle), "recommendation": "NEEDS_HUMAN_REVIEW",
        "readinessProbability": None, "probabilitySource": None, "calibration": "UNCALIBRATED",
        "risk": "UNKNOWN", "authorization": "NONE", "blockers": blockers, "runs": [],
        "exploratory": bool(blockers) or bundle["cohort"] == "SYNTHETIC",
        "historicalBenchmarkEligible": bundle["cohort"] == "HISTORICAL"
            and bundle["reconstruction"]["status"] == "EXACT",
        "modelOnlyDiagnostic": None, "modelMetadata": provider.metadata, "usage": None,
    }
    if failed_check:
        result["recommendation"] = "REQUEST_CHANGES"
        return result
    if blockers and not can_describe:
        return result
    prompt = make_prompt(bundle)
    assessments = []
    for run in range(2):
        record: dict[str, Any] = {"index": run + 1, "status": "FAILED", "assessment": None, "attempts": []}
        result["runs"].append(record)
        for attempt in range(max_attempts):
            is_cancelled(cancel_file)
            entry: dict[str, Any] = {"index": attempt + 1, "status": "FAILED", "error": None,
                                     "usage": None, "model": provider.metadata["model"]}
            record["attempts"].append(entry)
            try:
                response = await bounded_assess(provider, bundle, prompt, run, deadline, cancel_file)
                entry["usage"] = response["usage"]
                entry["model"] = response["model"]
                if response["model"] != provider.metadata["model"]:
                    raise AssessmentFailure("MODEL_MISMATCH")
                assessment = parse_json(response["text"])
                validate_assessment(assessment, bundle)
                record.update(status="VALID", assessment=assessment)
                entry["status"] = "VALID"
                assessments.append(assessment)
                break
            except TimeoutError:
                entry["error"] = "ASSESSMENT_DEADLINE"
            except CapabilityError as error:
                entry["error"] = str(error)
                blockers.append(blocker("LIVE_CAPABILITY_NO_GO", [], str(error)))
                return result
            except (ContractError, AssessmentFailure) as error:
                entry["error"] = str(error)
        if record["status"] != "VALID":
            blockers.append(blocker("ASSESSMENT_FAILED", [], "A required independent assessment failed validation or its deadline."))
            return result
    primary, challenger = assessments
    if blockers:
        result["modelOnlyDiagnostic"] = {
            "recommendation": primary["recommendation"],
            "readinessProbability": primary["readinessProbability"],
            "calibration": "UNCALIBRATED", "policyEligible": False,
        }
        return result
    result["risk"] = max((a["risk"] for a in assessments),
                         key=lambda risk: ["LOW", "MEDIUM", "HIGH", "CRITICAL", "UNKNOWN"].index(risk))
    if primary["recommendation"] != challenger["recommendation"]:
        blockers.append(blocker("ASSESSOR_DISAGREEMENT", [], "Independent recommendations disagree."))
    elif primary["recommendation"] == "APPROVE" and any(
        assessment["readinessProbability"] < MIN_MODEL_SUPPORT for assessment in assessments
    ):
        blockers.append(blocker("LOW_MODEL_SUPPORT", [],
                                "Both independent direct estimates must meet the uncalibrated 0.9 MVP support floor."))
    elif primary["recommendation"] in ("APPROVE", "REQUEST_CHANGES"):
        result["recommendation"] = primary["recommendation"]
        result["readinessProbability"] = primary["readinessProbability"]
        result["probabilitySource"] = "PRIMARY_DIRECT_ESTIMATE"
        result["blockers"] = primary["blockers"] + challenger["blockers"]
    else:
        result["blockers"] = primary["blockers"] + challenger["blockers"] + [
            blocker("MODEL_ABSTENTION", [], "Independent assessments did not establish readiness.")
        ]
    return result


def read_bundles(path: Path, max_cases: int) -> list[dict[str, Any]]:
    paths = sorted(path.glob("*.bundle.json")) if path.is_dir() else [path]
    if not paths or len(paths) > max_cases:
        raise ContractError("CASE_COUNT_OUT_OF_BOUNDS_NO_SILENT_TRUNCATION")
    bundles = [load_json(item) for item in paths]
    for bundle in bundles:
        validate_bundle(bundle)
    ids = [bundle["caseId"].casefold() for bundle in bundles]
    if len(set(ids)) != len(ids):
        raise ContractError("DUPLICATE_CASE_ID")
    return sorted(bundles, key=lambda bundle: bundle["caseId"])


def assert_output_root(path: Path) -> Path:
    def is_link(item: Path) -> bool:
        try:
            info = item.lstat()
        except FileNotFoundError:
            return False
        return stat.S_ISLNK(info.st_mode) or bool(
            getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
        )

    resolved = path.resolve()
    if resolved == resolved.parent or resolved == Path.home().resolve():
        raise ContractError("DEDICATED_OUTPUT_DIRECTORY_REQUIRED")
    for parent in (resolved, *resolved.parents):
        if (parent / ".git").exists() or parent == ROOT:
            raise ContractError("OUTPUT_MUST_BE_OUTSIDE_GIT_WORKTREES")
        if is_link(parent):
            raise ContractError("OUTPUT_SYMLINK_NOT_ALLOWED")
    for parent in (path.absolute(), *path.absolute().parents):
        if is_link(parent):
            raise ContractError("OUTPUT_SYMLINK_NOT_ALLOWED")
    if resolved.exists() and any(is_link(p) for p in resolved.rglob("*")):
        raise ContractError("OUTPUT_SYMLINK_NOT_ALLOWED")
    return resolved


@contextmanager
def exclusive_output(root: Path):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / ".lock").open("a+b") as lock:
        if lock.tell() == 0:
            lock.write(b"0")
            lock.flush()
        lock.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise ContractError("OUTPUT_LOCKED") from error
        try:
            yield
        finally:
            lock.seek(0)
            if os.name == "nt":
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(prefix=".replay-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def pipeline_fingerprint(settings: dict[str, Any]) -> str:
    files = sorted(ROOT.glob("*.py")) + sorted((ROOT / "schemas").glob("*.json"))
    files += sorted(ROOT.glob("requirements*.txt"))
    wrapper = ROOT.parent.parent / "tools" / "Invoke-SignoffReplay.ps1"
    files.append(wrapper)
    dependencies = {}
    manifests = [ROOT / "requirements.txt"]
    if settings.get("mode") == "live":
        manifests.append(ROOT / "requirements-live.txt")
    for manifest in manifests:
        for line in manifest.read_text(encoding="utf-8").splitlines():
            if "==" in line:
                name = line.split("==", 1)[0]
                dependencies[name] = importlib.metadata.version(name)
    return digest({
        "files": {str(path.relative_to(ROOT.parent.parent)): digest(path.read_text(encoding="utf-8")) for path in files},
        "settings": settings, "python": platform.python_version(),
        "dependencies": dependencies,
    })


def metrics(bundles: list[dict[str, Any]], results: list[dict[str, Any]]) -> dict[str, Any]:
    groups = {}
    for cohort in ("NATURAL", "HISTORICAL", "SYNTHETIC"):
        pairs = [(b, r) for b, r in zip(bundles, results) if b["cohort"] == cohort]
        eligible = [(b, r) for b, r in pairs if cohort != "HISTORICAL" or r["historicalBenchmarkEligible"]]
        labeled = [(b, r) for b, r in eligible if b["label"] is not None]
        matrix = {actual: {predicted: 0 for predicted in RECOMMENDATIONS} for actual in RECOMMENDATIONS}
        for bundle, result in labeled:
            matrix[bundle["label"]["recommendation"]][result["recommendation"]] += 1
        groups[cohort] = {
            "total": len(pairs), "families": len({b["familyId"] for b, _ in pairs}),
            "eligible": len(eligible), "ineligible": len(pairs) - len(eligible),
            "labeled": len(labeled), "unlabeledEligible": len(eligible) - len(labeled),
            "abstentions": sum(r["recommendation"] == "NEEDS_HUMAN_REVIEW" for _, r in pairs),
            "confusionMatrix": matrix, "accuracy": None,
        }
    return {"schemaVersion": 1, "cohorts": groups, "accuracyClaim": None,
            "note": "Counts are snapshot-level, correlated within PR families. Synthetic controls are not model accuracy. No calibration claim."}


def write_aggregate(root: Path, bundles: list[dict[str, Any]], results: list[dict[str, Any]]) -> None:
    atomic_write(root / "results.jsonl", "".join(canonical(result) + "\n" for result in results))
    report = metrics(bundles, results)
    atomic_write(root / "metrics.json", canonical(report) + "\n")
    lines = ["# Sign-off replay", "", "Advisory only. Authorization: NONE. Probabilities: UNCALIBRATED.",
             "Synthetic/current-snapshot results are exploratory, not historical benchmark evidence.", "",
             "| Case | Recommendation | Risk | Direct probability | Blockers |",
             "|---|---|---|---|---|"]
    for result in results:
        codes = ", ".join(sorted({b["code"] for b in result["blockers"]})) or "none"
        lines.append(f"| {result['caseId']} | {result['recommendation']} | {result['risk']} | "
                     f"{result['readinessProbability']} | {codes} |")
    lines += ["", "## Denominators", "", canonical(report)]
    atomic_write(root / "summary.md", "\n".join(lines) + "\n")


async def run_replay(bundles: list[dict[str, Any]], provider: Provider, root: Path,
                     settings: dict[str, Any], resume: bool, cancel_file: Path | None = None) -> list[dict[str, Any]]:
    root = assert_output_root(root)
    pipeline = pipeline_fingerprint(settings)
    manifest = {"schemaVersion": 1, "inputFingerprint": digest(bundles),
                "pipelineFingerprint": pipeline, "settings": settings,
                "caseIds": [b["caseId"] for b in bundles]}
    with exclusive_output(root):
        manifest_path = root / "manifest.json"
        if manifest_path.exists():
            if not resume:
                raise ContractError("OUTPUT_EXISTS_USE_EXACT_RESUME_OR_NEW_ROOT")
            if load_json(manifest_path) != manifest:
                raise ContractError("RESUME_FINGERPRINT_MISMATCH")
        elif resume:
            raise ContractError("RESUME_REQUIRES_EXISTING_MANIFEST")
        elif any(p.name != ".lock" for p in root.iterdir()):
            raise ContractError("OUTPUT_ROOT_NOT_EMPTY")
        else:
            atomic_write(manifest_path, canonical(manifest) + "\n")
        results = []
        capability_failure = None
        for bundle in bundles:
            is_cancelled(cancel_file)
            path = root / "cases" / (bundle["caseId"] + ".json")
            if path.exists():
                stored = load_json(path)
                if not isinstance(stored, dict) or set(stored) != {"result", "digest"} or not isinstance(stored["result"], dict):
                    raise ContractError("RESUME_RESULT_INTEGRITY_MISMATCH")
                result = stored.get("result")
                if stored.get("digest") != digest(result) or result.get("inputFingerprint") != digest(bundle) \
                        or result.get("pipelineFingerprint") != pipeline:
                    raise ContractError("RESUME_RESULT_INTEGRITY_MISMATCH")
                validate_result(result, bundle)
            else:
                effective_provider = provider
                if capability_failure is not None:
                    class BlockedProvider:
                        metadata = provider.metadata

                        async def assess(self, *_args):
                            raise CapabilityError(capability_failure)
                    effective_provider = BlockedProvider()
                result = await evaluate(bundle, effective_provider, settings["deadlineSeconds"], settings["maxAttempts"],
                                        settings["exploratory"], cancel_file)
                result["pipelineFingerprint"] = pipeline
                validate_result(result, bundle)
                atomic_write(path, canonical({"digest": digest(result), "result": result}) + "\n")
            for item in result["blockers"]:
                if item["code"] == "LIVE_CAPABILITY_NO_GO":
                    capability_failure = item["reason"]
            results.append(result)
        write_aggregate(root, bundles, results)
        return results
