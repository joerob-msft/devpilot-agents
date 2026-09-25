"""Prospective observer: append-only study ledger; no provider mutations or outcome prompts."""
from __future__ import annotations

import argparse
import asyncio
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import os
import json
from pathlib import Path
import sqlite3
import sys
import uuid
from typing import Any

from contracts import ContractError, canonical, digest, load_json, timestamp, validate_result
from observer_contracts import file_hash, validate, validate_config, validate_page
from replay import (CapabilityError, Cancelled, FixtureProvider, assert_output_root, atomic_write,
                    evaluate, exclusive_output, is_cancelled, pipeline_fingerprint, prechecks)

# The consumer allows 600 seconds of collection; leave time for transport teardown.
COLLECTOR_TIMEOUT_SECONDS = 660


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def instant(value: str) -> str:
    return timestamp(value).astimezone(timezone.utc).isoformat()


def snapshot_key(bundle: dict[str, Any], observation: dict[str, Any], pipeline: str) -> str:
    # Export/capture IDs and timestamps change each poll, unlike snapshot-bound evidence.
    evidence = [{key: value for key, value in item.items() if key != "observedAt"} for item in bundle["evidence"]]
    provenance = {key: value for key, value in bundle["provenance"].items() if key not in ("cutoff", "exportedAt")}
    return digest({"family": bundle["familyId"], "provenance": provenance, "evidence": evidence,
                   "guidance": bundle["guidance"], "completeness": bundle["completeness"], "pipeline": pipeline,
                   "observation": {key: value for key, value in observation.items()
                                   if key not in ("capturedAt", "baselineDecision", "state")}})


class Ledger:
    def __init__(self, root: Path, config: dict[str, Any], frozen: str, now: str):
        self.root = root
        self.db = sqlite3.connect(root / "observer.sqlite", timeout=0)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS study(id TEXT PRIMARY KEY, frozen TEXT, started TEXT, deadline TEXT, config TEXT);
          CREATE TABLE IF NOT EXISTS captures(id TEXT PRIMARY KEY, captured TEXT, payload TEXT);
          CREATE TABLE IF NOT EXISTS enrollments(family TEXT PRIMARY KEY, pr TEXT, captured TEXT, baseline TEXT, cohort TEXT);
          CREATE TABLE IF NOT EXISTS observations(id INTEGER PRIMARY KEY, family TEXT, captured TEXT, state TEXT, approval TEXT, payload TEXT);
          CREATE TABLE IF NOT EXISTS snapshots(key TEXT PRIMARY KEY, family TEXT, captured TEXT, payload TEXT, observation TEXT);
          CREATE TABLE IF NOT EXISTS admissions(id TEXT PRIMARY KEY, snapshot TEXT UNIQUE, admitted TEXT, mode TEXT);
          CREATE TABLE IF NOT EXISTS decisions(id TEXT PRIMARY KEY, snapshot TEXT, started TEXT, finished TEXT, mode TEXT, status TEXT, result TEXT);
          CREATE TABLE IF NOT EXISTS outcomes(id TEXT PRIMARY KEY, family TEXT, captured TEXT, payload TEXT);
          CREATE TABLE IF NOT EXISTS gaps(id INTEGER PRIMARY KEY, captured TEXT, code TEXT, family TEXT, reason TEXT);
          CREATE TABLE IF NOT EXISTS reports(id TEXT PRIMARY KEY, captured TEXT, payload TEXT);
          CREATE TABLE IF NOT EXISTS guidance(id TEXT PRIMARY KEY, payload TEXT);
          CREATE TABLE IF NOT EXISTS adjudications(id TEXT PRIMARY KEY, captured TEXT, payload TEXT);
        """)
        for table in ("study", "captures", "enrollments", "observations", "snapshots", "admissions", "decisions", "outcomes", "gaps", "reports", "guidance", "adjudications"):
            for operation in ("UPDATE", "DELETE"):
                self.db.execute(f"CREATE TRIGGER IF NOT EXISTS immutable_{table}_{operation} BEFORE {operation} ON {table} "
                                "BEGIN SELECT RAISE(ABORT,'immutable observer history'); END")
        try:
            with self.db:
                current = self.db.execute("SELECT * FROM study").fetchone()
                if current is None:
                    deadline = (timestamp(now) + timedelta(days=7)).isoformat()
                    self.db.execute("INSERT INTO study VALUES(?,?,?,?,?)", (config["studyId"], frozen, instant(now), deadline, canonical(config)))
                elif current["id"] != config["studyId"] or current["frozen"] != frozen:
                    raise ContractError("OBSERVER_STUDY_FINGERPRINT_MISMATCH_NEW_STUDY_REQUIRED")
        except (ContractError, sqlite3.Error):
            self.db.close()
            raise
        self.study = dict(self.db.execute("SELECT * FROM study").fetchone())

    def gap(self, code: str, family: str | None, reason: str, now: str) -> None:
        self.db.execute("INSERT INTO gaps(captured,code,family,reason) VALUES(?,?,?,?)", (instant(now), code, family, reason))

    def expired(self, now: str) -> bool:
        return timestamp(now) >= timestamp(self.study["deadline"])

    def tracked(self) -> list[dict[str, str]]:
        return [{"familyId": row["family"], "pullRequestId": row["pr"]}
                for row in self.db.execute("SELECT family,pr FROM enrollments ORDER BY family")]

    def ingest(self, page: dict[str, Any], request: dict[str, Any], pipeline: str) -> list[str]:
        validate_page(page, request)
        page_id = page["captureId"] + ":" + digest(page["page"]["cursor"])
        existing = self.db.execute("SELECT payload FROM captures WHERE id=?", (page_id,)).fetchone()
        if existing:
            if existing["payload"] != canonical(page):
                raise ContractError("CAPTURE_ID_COLLISION")
            return []
        now = page["window"]["completedAt"]
        keys = []
        with self.db:
            self.db.execute("INSERT INTO captures VALUES(?,?,?)", (page_id, instant(now), canonical(page)))
            for gap in page["gaps"]:
                self.gap(gap["code"], gap["familyId"], gap["reason"], now)
            snapshots = {item["bundle"]["familyId"]: item for item in page["snapshots"]}
            for inventory in page["inventory"]:
                family = inventory["familyId"]
                snapshot = snapshots.get(family)
                baseline = snapshot["observation"]["baselineDecision"] if snapshot else "UNKNOWN"
                cohort = snapshot["bundle"]["cohort"] if snapshot else "UNKNOWN"
                enrollment = self.db.execute("SELECT pr FROM enrollments WHERE family=?", (family,)).fetchone()
                previous_snapshot = self.db.execute("SELECT payload FROM snapshots WHERE family=? LIMIT 1", (family,)).fetchone()
                if enrollment and enrollment["pr"] != inventory["pullRequestId"]:
                    raise ContractError("FAMILY_PR_IDENTITY_CHANGED")
                if snapshot and previous_snapshot:
                    previous_provenance = json.loads(previous_snapshot["payload"])["provenance"]
                    if any(previous_provenance[k] != snapshot["bundle"]["provenance"][k] for k in ("provider", "repository", "pullRequestId")):
                        raise ContractError("FAMILY_REPOSITORY_IDENTITY_CHANGED")
                self.db.execute("INSERT OR IGNORE INTO enrollments VALUES(?,?,?,?,?)",
                                (family, inventory["pullRequestId"], instant(now), baseline, cohort))
                prior = self.db.execute("SELECT * FROM observations WHERE family=? ORDER BY captured DESC,id DESC LIMIT 1",
                                        (family,)).fetchone()
                if prior and timestamp(prior["captured"]) > timestamp(now):
                    self.gap("OUT_OF_ORDER_CAPTURE", family, "Preserved capture; cannot replace current state or trigger inference.", now)
                    continue
                if prior and prior["state"] != inventory["state"]:
                    self.gap("STATE_TRANSITION", family, prior["state"] + " -> " + inventory["state"], now)
                if prior and prior["approval"] == "APPROVED" and baseline == "NOT_APPROVED":
                    self.gap("APPROVAL_RESET_OBSERVED", family, "Observed reset; actual event time remains unknown.", now)
                self.db.execute("INSERT INTO observations(family,captured,state,approval,payload) VALUES(?,?,?,?,?)",
                                (family, instant(now), inventory["state"], baseline, canonical({**inventory, "hasSnapshot": snapshot is not None})))
                if not snapshot:
                    self.gap("SNAPSHOT_UNAVAILABLE", family, "Inventory member lacks an evaluable evidence bundle.", now)
                    continue
                observation = snapshot["observation"]
                if previous_snapshot and json.loads(previous_snapshot["payload"])["guidance"] != snapshot["bundle"]["guidance"]:
                    self.gap("GUIDANCE_CHANGED_NEW_STUDY_REQUIRED", family, "The family's guidance set is frozen at first capture.", now)
                    observation = {**observation, "eligibilityReasons":
                                   list(dict.fromkeys(observation["eligibilityReasons"] + ["GUIDANCE_CHANGED"]))}
                for guide in snapshot["bundle"]["guidance"]:
                    pinned = self.db.execute("SELECT payload FROM guidance WHERE id=?", (guide["id"],)).fetchone()
                    if pinned and pinned["payload"] != canonical(guide):
                        self.gap("GUIDANCE_CHANGED_NEW_STUDY_REQUIRED", family, "Approved guidance is pinned by ID for this study.", now)
                        observation = {**observation, "eligibilityReasons":
                                       list(dict.fromkeys(observation["eligibilityReasons"] + ["GUIDANCE_CHANGED"]))}
                    elif not pinned:
                        self.db.execute("INSERT INTO guidance VALUES(?,?)", (guide["id"], canonical(guide)))
                if inventory["isDraft"] and "DRAFT" not in observation["eligibilityReasons"]:
                    observation = {**observation, "eligibilityReasons": observation["eligibilityReasons"] + ["DRAFT"]}
                key = snapshot_key(snapshot["bundle"], observation, pipeline)
                inserted = self.db.execute("INSERT OR IGNORE INTO snapshots VALUES(?,?,?,?,?)",
                    (key, family, instant(observation["capturedAt"]), canonical(snapshot["bundle"]), canonical(observation)))
                if inserted.rowcount:
                    keys.append(key)
            for outcome in page["outcomes"]:
                old = self.db.execute("SELECT payload FROM outcomes WHERE id=?", (outcome["id"],)).fetchone()
                if old:
                    # capturedAt is a transport observation, not a new outcome event.
                    previous = json.loads(old["payload"])
                    if {k: v for k, v in previous.items() if k != "capturedAt"} != {k: v for k, v in outcome.items() if k != "capturedAt"}:
                        raise ContractError("OUTCOME_ID_COLLISION")
                else:
                    self.db.execute("INSERT INTO outcomes VALUES(?,?,?,?)",
                                    (outcome["id"], outcome["familyId"], instant(outcome["capturedAt"]), canonical(outcome)))
        return keys

    def admit(self, key: str, config: dict[str, Any], now: str) -> str | None:
        evaluation = config["evaluation"]
        if self.expired(now):
            return None
        day = instant(now)[:10]
        with self.db:
            count = self.db.execute("SELECT COUNT(*) FROM admissions").fetchone()[0]
            daily = self.db.execute("SELECT COUNT(*) FROM admissions WHERE substr(admitted,1,10)=?", (day,)).fetchone()[0]
            if count >= evaluation["studyLimit"] or daily >= evaluation["dailyLimit"]:
                self.gap("EVALUATION_BUDGET_BLOCKED", None, "Collection continues; daily/study admission limit exhausted.", now)
                return None
            admission = uuid.uuid4().hex
            self.db.execute("INSERT INTO admissions VALUES(?,?,?,?)", (admission, key, instant(now), evaluation["mode"]))
            return admission

    def recover(self, now: str) -> None:
        with self.db:
            rows = self.db.execute("SELECT * FROM admissions WHERE id NOT IN (SELECT id FROM decisions)").fetchall()
            for row in rows:
                self.db.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?,?)",
                    (row["id"], row["snapshot"], row["admitted"], instant(now), row["mode"], "INTERRUPTED_UNKNOWN_USAGE", None))
                self.gap("INTERRUPTED_ASSESSMENT", None, "Reserved evaluation consumed; no automatic model resend.", now)

    def close(self) -> None:
        self.db.close()


def prospective_eligible(observation: dict[str, Any]) -> bool:
    return (observation["stable"] and observation["state"] == "ACTIVE"
            and not observation["eligibilityReasons"] and observation["baselineDecision"] == "NOT_APPROVED")


async def assess_pending(ledger: Ledger, config: dict[str, Any], pipeline: str,
                         provider_factory, now=utc_now, cancel_file: Path | None = None) -> None:
    import json
    evaluation = config["evaluation"]
    rows = ledger.db.execute("SELECT * FROM snapshots WHERE key NOT IN (SELECT snapshot FROM decisions) "
                             "ORDER BY captured,key").fetchall()
    fatal = ledger.db.execute("SELECT 1 FROM gaps WHERE code='MODEL_RUNTIME_BLOCKED' LIMIT 1").fetchone()
    for row in rows:
        is_cancelled(cancel_file)
        if ledger.expired(now()):
            break
        bundle, observation = json.loads(row["payload"]), json.loads(row["observation"])
        current = ledger.db.execute("SELECT key FROM snapshots WHERE family=? ORDER BY captured DESC,rowid DESC LIMIT 1",
                                    (row["family"],)).fetchone()
        latest_observation = ledger.db.execute("SELECT * FROM observations WHERE family=? ORDER BY captured DESC,id DESC LIMIT 1",
                                              (row["family"],)).fetchone()
        if latest_observation and (latest_observation["state"] != "ACTIVE"
                                   or latest_observation["approval"] == "APPROVED"
                                   or not json.loads(latest_observation["payload"])["hasSnapshot"]):
            status = "LATEST_OBSERVATION_INELIGIBLE"
        elif current and current["key"] != row["key"]:
            # Old captures never regain admission when a later head/evidence version is observed.
            status = "SUPERSEDED_BEFORE_ASSESSMENT"
        elif not observation["stable"] or observation["state"] != "ACTIVE" or observation["eligibilityReasons"]:
            status = "OBSERVATION_INELIGIBLE"
        elif evaluation["mode"] == "collection-only":
            status = "COLLECTION_ONLY"
        elif fatal:
            status = "MODEL_RUNTIME_BLOCKED"
        else:
            status = ""
        started = now()
        if status:
            with ledger.db:
                ledger.db.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?,?)",
                                  (uuid.uuid4().hex, row["key"], instant(started), instant(started), evaluation["mode"], status, None))
            continue
        # Deterministic policy failures still produce a result without consuming model admissions.
        checks = prechecks(bundle, prospective=True)
        complete_code_intent = all(c["status"] == "COMPLETE" for c in bundle["completeness"] if c["category"] in ("CODE", "INTENT"))
        will_infer = not checks or (evaluation["exploratory"] and complete_code_intent
                                   and all(g["approved"] for g in bundle["guidance"])
                                   and not any(b["code"] == "DETERMINISTIC_CODE_FAILURE" for b in checks))
        admission = ledger.admit(row["key"], config, started) if will_infer else uuid.uuid4().hex
        if admission is None:
            continue
        try:
            provider = provider_factory(bundle) if will_infer else NoModelProvider(evaluation["model"])
            result = await evaluate(bundle, provider, evaluation["deadlineSeconds"], evaluation["maxAttempts"],
                                    evaluation["exploratory"], cancel_file, prospective=True)
            result["pipelineFingerprint"] = pipeline
            result["historicalBenchmarkEligible"] = False
            validate_result(result, bundle)
            finished = now()
            with ledger.db:
                ledger.db.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?,?)",
                                  (admission, row["key"], instant(started), instant(finished), evaluation["mode"], "COMPLETED", canonical(result)))
                if any(b["code"] == "LIVE_CAPABILITY_NO_GO" for b in result["blockers"]):
                    ledger.gap("MODEL_RUNTIME_BLOCKED", row["family"], "Runtime safety/capability failure; collection only until a new study.", finished)
                    fatal = True
        except CapabilityError as error:
            with ledger.db:
                ledger.db.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?,?)",
                                  (admission, row["key"], instant(started), instant(now()), evaluation["mode"], "MODEL_RUNTIME_BLOCKED", None))
                ledger.gap("MODEL_RUNTIME_BLOCKED", row["family"], str(error), now())
            fatal = True


class NoModelProvider:
    def __init__(self, model=None):
        self.metadata = {"provider": "none", "model": model or "collection-only", "sdk": None, "runtime": None}

    async def assess(self, *_args):
        raise CapabilityError("NO_MODEL_PROVIDER")


def report(ledger: Ledger, now: str) -> dict[str, Any]:
    import json
    decisions = []
    for row in ledger.db.execute("SELECT d.*,s.family,s.payload,s.observation FROM decisions d JOIN snapshots s ON s.key=d.snapshot ORDER BY finished,id"):
        item = dict(row)
        item["bundle"] = json.loads(item.pop("payload"))
        item["observation"] = json.loads(item["observation"])
        item["result"] = json.loads(item["result"]) if item["result"] else None
        decisions.append(item)
    outcomes = [json.loads(row["payload"]) for row in ledger.db.execute("SELECT payload FROM outcomes ORDER BY captured,id")]
    cohorts = {}
    for cohort in ("NATURAL", "SYNTHETIC", "UNKNOWN"):
        enrollments = [dict(row) for row in ledger.db.execute("SELECT * FROM enrollments WHERE cohort=?", (cohort,))]
        enrolled_families = {item["family"] for item in enrollments}
        subset = [item for item in decisions if item["family"] in enrolled_families]
        cohorts[cohort] = {
            "families": len(enrollments), "baselineApproved": sum(e["baseline"] == "APPROVED" for e in enrollments),
            "baselineUnknown": sum(e["baseline"] == "UNKNOWN" for e in enrollments), "decisions": len(subset),
            "abstentions": sum(item["result"] is not None and item["result"]["recommendation"] == "NEEDS_HUMAN_REVIEW" for item in subset),
            "noPrediction": sum(not any(item["family"] == e["family"] and item["result"] is not None for item in decisions) for e in enrollments),
            "noPredictionDecisions": sum(item["result"] is None for item in subset),
            "censoredFamilies": sum(not any(o["familyId"] == e["family"] and o["kind"] in ("APPROVED", "CHANGES_REQUESTED", "COMPLETED", "ABANDONED") for o in outcomes) for e in enrollments),
        }
    matching = []
    excluded = {}
    for outcome in outcomes:
        reason = None
        if outcome["actorKind"] != "HUMAN":
            reason = "actor_not_human"
        elif outcome["kind"] not in ("APPROVED", "CHANGES_REQUESTED"):
            reason = "not_readiness_ground_truth"
        elif not outcome["occurredAt"]:
            reason = "unknown_event_time"
        elif outcome["iteration"] is None:
            reason = "unknown_iteration"
        enrollment = ledger.db.execute("SELECT * FROM enrollments WHERE family=?", (outcome["familyId"],)).fetchone()
        if not reason and (not enrollment or enrollment["baseline"] != "NOT_APPROVED"):
            reason = "baseline_not_unapproved"
        candidates = []
        if not reason:
            for item in decisions:
                bundle, result = item["bundle"], item["result"]
                provenance = bundle["provenance"]
                if item["family"] != outcome["familyId"] or item["mode"] != "live" or bundle["cohort"] != "NATURAL" or result is None:
                    continue
                if any(provenance[key] != outcome[key] for key in ("sourceCommit", "targetCommit", "iteration")):
                    continue
                if not prospective_eligible(item["observation"]) or result["modelOnlyDiagnostic"] is not None:
                    continue
                if any(b["code"] != "DETERMINISTIC_CODE_FAILURE" for b in prechecks(bundle, prospective=True)):
                    continue
                if not timestamp(provenance["cutoff"]) <= timestamp(item["finished"]) < timestamp(outcome["occurredAt"]):
                    continue
                # A delayed prior decision event can retrospectively disqualify a prediction.
                prior = any(o["familyId"] == item["family"] and o["actorKind"] == "HUMAN"
                            and o["kind"] in ("APPROVED", "CHANGES_REQUESTED")
                            and o["occurredAt"] and timestamp(o["occurredAt"]) <= timestamp(item["finished"])
                            and all(o[key] == provenance[key] for key in ("sourceCommit", "targetCommit", "iteration"))
                            for o in outcomes)
                if not prior:
                    candidates.append(item)
            if not candidates:
                reason = "no_eligible_predecision_prediction"
        if reason:
            excluded[reason] = excluded.get(reason, 0) + 1
            continue
        selected = max(candidates, key=lambda item: (timestamp(item["finished"]), item["id"]))
        expected = "APPROVE" if outcome["kind"] == "APPROVED" else "REQUEST_CHANGES"
        matching.append({"outcomeId": outcome["id"], "decisionId": selected["id"], "familyId": outcome["familyId"],
                         "expected": expected, "predicted": selected["result"]["recommendation"],
                         "leadSeconds": (timestamp(outcome["occurredAt"]) - timestamp(selected["finished"])).total_seconds()})
    matrix = {label: {p: 0 for p in ("APPROVE", "REQUEST_CHANGES", "NEEDS_HUMAN_REVIEW")}
              for label in ("APPROVE", "REQUEST_CHANGES")}
    for match in matching:
        matrix[match["expected"]][match["predicted"]] += 1
    latest = {}
    for item in decisions:
        result = item["result"]
        latest[item["family"]] = {
            "familyId": item["family"], "sourceCommit": item["bundle"]["provenance"]["sourceCommit"],
            "targetCommit": item["bundle"]["provenance"]["targetCommit"], "status": item["status"],
            "recommendation": result["recommendation"] if result else "NEEDS_HUMAN_REVIEW",
            "modelOnlyDiagnostic": result["modelOnlyDiagnostic"] if result else None,
            "reasons": [b["code"] for b in result["blockers"]] if result else [item["status"]],
        }
    return {
        "schemaVersion": 1, "studyId": ledger.study["id"], "startedAt": ledger.study["started"],
        "deadline": ledger.study["deadline"], "asOf": instant(now), "final": ledger.expired(now),
        "authorization": "NONE", "cohorts": cohorts, "outcomes": len(outcomes),
        "livePolicyAgreement": {"eligible": len(matching), "excluded": excluded, "confusionMatrix": matrix, "matches": matching},
        "admissions": ledger.db.execute("SELECT COUNT(*) FROM admissions").fetchone()[0],
        "gaps": [dict(row) for row in ledger.db.execute("SELECT code,COUNT(*) count FROM gaps GROUP BY code ORDER BY code")],
        "latest": list(latest.values()), "backendVersion": None,
        "humanAdjudications": [json.loads(row["payload"]) for row in ledger.db.execute("SELECT payload FROM adjudications ORDER BY captured,id")],
        "limitations": "Uncalibrated advisory; same-model runs may be correlated. Lead time is not time saved. Completion is not readiness ground truth. Polling misses transient states; unknown event times are excluded. No approval authorization.",
    }


def persist_report(ledger: Ledger, now: str) -> dict[str, Any]:
    value = report(ledger, now)
    with ledger.db:
        ledger.db.execute("INSERT OR IGNORE INTO reports VALUES(?,?,?)", (digest(value), instant(now), canonical(value)))
    daily = instant(now)[:10]
    root = ledger.root / "reports"
    # Immutable report versions plus convenient daily/latest pointers.
    atomic_write(root / (digest(value) + ".json"), canonical(value) + "\n")
    for name in (daily, "latest", *(["final"] if value["final"] else [])):
        atomic_write(root / (name + ".json"), canonical(value) + "\n")
        lines = ["# Sign-off observer", "", f"Study: {value['studyId']}; deadline: {value['deadline']}", "",
                 value["limitations"], "", "Final policy and model-only diagnostics are distinct.", "",
                 "| Family | Final policy | Model-only diagnostic | Gaps |", "|---|---|---|---|"]
        for row in value["latest"]:
            safe_family = row["familyId"].replace("|", "\\|").replace("\n", " ")
            diagnostic = (row["modelOnlyDiagnostic"] or {}).get("recommendation", "none")
            lines.append(f"| {safe_family} | {row['recommendation']} | {diagnostic} | {', '.join(row['reasons'])} |")
        lines += ["", "## Cohort denominators", canonical(value["cohorts"]), "", "## Prospective agreement (not accuracy)", canonical(value["livePolicyAgreement"])]
        atomic_write(root / (name + ".md"), "\n".join(lines) + "\n")
    return value


class Events:
    def __init__(self, root: Path):
        self.instance = str(uuid.uuid4())
        self.path = root / "logs" / "events" / "signoff-observer" / (self.instance + ".jsonl")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.sequence = 0
        self.cycle = 0

    def emit(self, kind: str, data=None, level="info"):
        self.sequence += 1
        event = {"schemaVersion": 2, "agent": "signoff-observer", "instanceId": self.instance,
                 "processId": os.getpid(), "timestamp": utc_now(), "sequence": self.sequence,
                 "eventType": kind, "level": level, "cycleNumber": self.cycle,
                 "pullRequestId": 0, "sourceCommit": "", "data": data or {}, "message": ""}
        with self.path.open("a", encoding="utf-8") as output:
            output.write(canonical(event) + "\n")


def import_adjudication(ledger: Ledger, value: dict[str, Any], now: str) -> None:
    validate(value, "observer-adjudication")
    if value["studyId"] != ledger.study["id"] or timestamp(value["adjudicatedAt"]) > timestamp(now):
        raise ContractError("ADJUDICATION_STUDY_OR_TIME_MISMATCH")
    row = ledger.db.execute("SELECT s.payload FROM decisions d JOIN snapshots s ON d.snapshot=s.key WHERE d.id=?",
                            (value["decisionId"],)).fetchone()
    if row is None:
        raise ContractError("ADJUDICATION_UNKNOWN_DECISION")
    refs = {item["id"] for item in json.loads(row["payload"])["evidence"]}
    if not set(value["evidenceRefs"]) <= refs:
        raise ContractError("ADJUDICATION_UNKNOWN_EVIDENCE")
    old = ledger.db.execute("SELECT payload FROM adjudications WHERE id=?", (value["id"],)).fetchone()
    if old and old["payload"] != canonical(value):
        raise ContractError("ADJUDICATION_ID_COLLISION")
    with ledger.db:
        ledger.db.execute("INSERT OR IGNORE INTO adjudications VALUES(?,?,?)", (value["id"], instant(now), canonical(value)))


async def collect_page(config: dict[str, Any], request: dict[str, Any], folder: Path,
                       toolkit: Path, pwsh: str, cancel_file: Path | None) -> dict[str, Any]:
    validate_config(config)
    validate(request, "observation-request")
    request_path, output_path = folder / "request.json", folder / "response.json"
    atomic_write(request_path, canonical(request) + "\n")
    started = asyncio.get_running_loop().time()
    # Private receipt for operator diagnosis; never ingested into model input or public events.
    with (folder / "collector.stderr.log").open("wb") as diagnostics:
        process = await asyncio.create_subprocess_exec(pwsh, "-NoProfile", "-NonInteractive", "-File",
            config["collector"]["scriptPath"], "-ConfigFile", config["collector"]["configPath"],
            "-RequestPath", str(request_path), "-OutputPath", str(output_path), "-LocalToolkitRoot", str(toolkit),
            stdout=asyncio.subprocess.DEVNULL, stderr=diagnostics, cwd=folder)
    try:
        async with asyncio.timeout(COLLECTOR_TIMEOUT_SECONDS):
            while process.returncode is None:
                is_cancelled(cancel_file)
                try:
                    await asyncio.wait_for(process.wait(), 0.2)
                except TimeoutError:
                    continue
        if process.returncode:
            raise ContractError("COLLECTOR_EXIT_" + str(process.returncode))
        page = load_json(output_path)
        validate_page(page, request)
        return page
    except (TimeoutError, Cancelled, asyncio.CancelledError) as error:
        code = "COLLECTOR_TIMEOUT" if isinstance(error, TimeoutError) else "COLLECTOR_CANCELLED"
        try:
            if process.returncode is None:
                process.kill()
            await process.wait()
        except OSError:
            raise CapabilityError(code + "_CLEANUP_FAILED_REQUIRES_CONTAINMENT_CLEANUP") from None
        try:
            atomic_write(folder / "collector.interruption.json", canonical({
                "code": code, "timeoutSeconds": COLLECTOR_TIMEOUT_SECONDS,
                "elapsedSeconds": asyncio.get_running_loop().time() - started,
                "authorization": "NONE",
            }) + "\n")
        except OSError:
            raise CapabilityError(code + "_DIAGNOSTIC_WRITE_FAILED_REQUIRES_CONTAINMENT_CLEANUP") from None
        # Outer Job Object contains MCP grandchildren; stop rather than launch another collector.
        raise CapabilityError(code + "_REQUIRES_CONTAINMENT_CLEANUP") from None


async def worker(args) -> int:
    config = load_json(args.config)
    validate_config(config)
    root = assert_output_root(Path(config["stateRoot"]))
    if config["evaluation"]["mode"] == "live" and not args.enable_model:
        raise ContractError("LIVE_OBSERVER_REQUIRES_EXPLICIT_EnableModel")
    if args.validate_only:
        print(canonical({"valid": True, "studyId": config["studyId"], "stateRoot": str(root), "mode": config["evaluation"]["mode"]}))
        return 0
    from sdk_adapter import require_containment
    require_containment()
    toolkit = Path(__file__).resolve().parents[2]
    pipeline = digest({"engine": pipeline_fingerprint({"observerConfig": config, "mode": config["evaluation"]["mode"]}),
                       "containment": {str(path.relative_to(toolkit)): file_hash(path) for path in (
                           toolkit / "src" / "Agents" / "signoff-observer" / "Start-SignoffObserver.ps1",
                           toolkit / "src" / "DevPilot.AgentHarness" / "DevPilot.AgentHarness.psm1",
                           toolkit / "src" / "DevPilot.AgentHarness" / "DevPilot.AgentHarness.psd1")}})
    runtime = config["evaluation"]["runtimePath"]
    fixture = config["evaluation"]["fixturePath"]
    if runtime:
        from sdk_adapter import runtime_fingerprint
        pipeline = digest({"pipeline": pipeline, "runtime": runtime_fingerprint(Path(runtime))})
    if fixture:
        pipeline = digest({"pipeline": pipeline, "fixture": file_hash(fixture)})
    events = Events(Path(args.state_dir) if args.state_dir else root)
    with exclusive_output(root):
        ledger = Ledger(root, config, pipeline, utc_now())
        ledger.recover(utc_now())
        if args.adjudication:
            try:
                import_adjudication(ledger, load_json(args.adjudication), utc_now())
                persist_report(ledger, utc_now())
                return 0
            finally:
                ledger.close()
        events.emit("agent.started", {"repository": config["studyId"], "writes": "none", "vote": "off", "capabilities": [],
                                     "observerMode": config["evaluation"]["mode"], "deadline": ledger.study["deadline"]})
        def provider(bundle):
            mode = config["evaluation"]["mode"]
            if mode == "offline":
                responses = load_json(Path(fixture))
                return FixtureProvider({"schemaVersion": 1, "cases": {bundle["caseId"]: responses["cases"][bundle["caseId"]]}},
                                       [bundle], config["evaluation"]["model"])
            if mode == "live":
                from sdk_adapter import SdkProvider
                return SdkProvider(Path(runtime), config["evaluation"]["model"], config["evaluation"]["maxAiCredits"])
            return NoModelProvider()
        async def heartbeat():
            while True:
                await asyncio.sleep(5)
                events.emit("agent.heartbeat")
        pulse = asyncio.create_task(heartbeat())
        try:
            while not ledger.expired(utc_now()):
                is_cancelled(args.cancel_file)
                events.cycle += 1
                events.emit("cycle.started")
                request = {"schemaVersion": 1, "studyId": config["studyId"], "captureId": uuid.uuid4().hex,
                           "startedAt": utc_now(), "cursor": None, "trackedPullRequests": ledger.tracked(),
                           "maxItems": config["maxItems"], "collectorConfigSha256": config["collector"]["configSha256"]}
                seen = set()
                complete = False
                for page_number in range(config["maxPages"]):
                    folder = root / "captures" / request["captureId"] / str(page_number)
                    folder.mkdir(parents=True)
                    try:
                        page = await collect_page(config, request, folder, Path(__file__).resolve().parents[2], args.pwsh, args.cancel_file)
                        ledger.ingest(page, request, pipeline)
                    except (ContractError, OSError) as error:
                        with ledger.db:
                            ledger.gap("CAPTURE_FAILED", None, type(error).__name__ + ":" + (str(error) if isinstance(error, ContractError) else "IO_ERROR"), utc_now())
                        events.emit("cycle.failed", {"reason": "Capture failed; preserved gaps and prior history."}, "error")
                        break
                    if page["page"]["complete"]:
                        complete = True
                        break
                    cursor = page["page"]["nextCursor"]
                    if cursor in seen:
                        with ledger.db:
                            ledger.gap("PAGINATION_CYCLE", None, "Repeated continuation token.", utc_now())
                        break
                    seen.add(cursor)
                    request = {**request, "cursor": cursor}
                if not complete:
                    with ledger.db:
                        ledger.gap("INVENTORY_INCOMPLETE", None, "No terminal page; no absence or completion inferred.", utc_now())
                if complete:
                    blocked_before = ledger.db.execute("SELECT 1 FROM gaps WHERE code='MODEL_RUNTIME_BLOCKED' LIMIT 1").fetchone()
                    await assess_pending(ledger, config, pipeline, provider, cancel_file=args.cancel_file)
                    if not blocked_before and ledger.db.execute("SELECT 1 FROM gaps WHERE code='MODEL_RUNTIME_BLOCKED' LIMIT 1").fetchone():
                        persist_report(ledger, utc_now())
                        raise CapabilityError("MODEL_RUNTIME_BLOCKED_RESTART_COLLECTION_ONLY_AFTER_CONTAINMENT_CLEANUP")
                value = persist_report(ledger, utc_now())
                events.emit("observer.updated", {"studyId": config["studyId"], "mode": config["evaluation"]["mode"],
                    "families": sum(c["families"] for c in value["cohorts"].values()), "admissions": value["admissions"],
                    "eligibleAgreement": value["livePolicyAgreement"]["eligible"], "deadline": value["deadline"],
                    "reportPath": str(root / "reports" / "latest.md"),
                    "collectionStatus": "complete" if complete else "incomplete",
                    "lastFamilyId": value["latest"][-1]["familyId"] if value["latest"] else "",
                    "finalRecommendation": value["latest"][-1]["recommendation"] if value["latest"] else "NEEDS_HUMAN_REVIEW",
                    "diagnostic": (value["latest"][-1]["modelOnlyDiagnostic"] or {}).get("recommendation", "none") if value["latest"] else "none",
                    "eligibilityReasons": (value["latest"][-1]["reasons"] if value["latest"] else ["NO_SNAPSHOTS"])
                        + ([] if complete else ["CAPTURE_INCOMPLETE"])})
                events.emit("cycle.completed", {"result": "observed" if complete else "partial", "scanned": len(ledger.tracked())})
                if args.once:
                    if not complete:
                        return 2
                    break
                events.emit("agent.waiting", {"kind": "observer polling", "delayMilliseconds": config["pollSeconds"] * 1000})
                stop = asyncio.get_running_loop().time() + config["pollSeconds"]
                while asyncio.get_running_loop().time() < stop and not ledger.expired(utc_now()):
                    is_cancelled(args.cancel_file)
                    events.emit("agent.heartbeat")
                    await asyncio.sleep(min(5, max(0, stop - asyncio.get_running_loop().time())))
            persist_report(ledger, utc_now())
            return 0
        except (CapabilityError, Cancelled, asyncio.CancelledError) as error:
            with ledger.db:
                code = str(error) if isinstance(error, CapabilityError) else "CANCELLED"
                ledger.gap("WORKER_INTERRUPTED", None,
                           code + ": owner exits for containment cleanup; unchanged-pipeline restart preserves admission and deadline.",
                           utc_now())
            persist_report(ledger, utc_now())
            raise
        finally:
            pulse.cancel()
            await asyncio.gather(pulse, return_exceptions=True)
            events.emit("agent.stopped")
            ledger.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--pwsh", default="pwsh")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--enable-model", action="store_true")
    parser.add_argument("--cancel-file", type=Path)
    parser.add_argument("--adjudication", type=Path)
    args = parser.parse_args()
    try:
        return asyncio.run(worker(args))
    except (ContractError, CapabilityError) as error:
        print(canonical({"error": str(error), "authorization": "NONE"}), file=sys.stderr)
        return 2
    except (Cancelled, KeyboardInterrupt):
        print('{"error":"CANCELLED","authorization":"NONE"}', file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
