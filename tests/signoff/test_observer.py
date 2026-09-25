from __future__ import annotations

import asyncio
import copy
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

from test_replay import FakeProvider, answer, bundle
from contracts import ContractError, canonical, digest, make_prompt
from observer import (COLLECTOR_TIMEOUT_SECONDS, Ledger, assess_pending, collect_page,
                      import_adjudication, persist_report, report, snapshot_key)
from observer_contracts import file_hash, validate_config, validate_page
from replay import Cancelled, CapabilityError, exclusive_output
from report_delivery import prepare


BASE = datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
FROZEN = "a" * 64


def time_at(minutes=0):
    return (BASE + timedelta(minutes=minutes)).isoformat()


def capture(number=0, value=None, *, state="ACTIVE", baseline="NOT_APPROVED"):
    value = copy.deepcopy(value or bundle())
    value["label"] = None
    value["reconstruction"]["status"] = "CURRENT_SNAPSHOT"
    value["provenance"].update(cutoff=time_at(number), exportedAt=time_at(number))
    request = {"schemaVersion": 1, "studyId": "study", "captureId": f"capture-{number}",
               "startedAt": time_at(number), "cursor": None, "trackedPullRequests": [],
               "maxItems": 25, "collectorConfigSha256": "a" * 64}
    page = {"schemaVersion": 1, "studyId": "study", "captureId": request["captureId"],
            "page": {"cursor": None, "nextCursor": None, "complete": True},
            "window": {"startedAt": time_at(number), "completedAt": time_at(number)},
            "inventory": [{"familyId": value["familyId"], "pullRequestId": value["provenance"]["pullRequestId"],
                           "targetRef": value["provenance"]["targetRef"], "state": state, "isDraft": False,
                           "sourceCommit": value["provenance"]["sourceCommit"], "targetCommit": value["provenance"]["targetCommit"]}],
            "snapshots": [{"bundle": value, "observation": {"capturedAt": time_at(number), "state": state,
                           "baselineDecision": baseline, "stable": True, "eligibilityReasons": []}}],
            "outcomes": [], "gaps": []}
    return request, page


def outcome(value, *, event_id="outcome", kind="APPROVED", at=10, captured=11, actor="HUMAN"):
    p = value["provenance"]
    return {"id": event_id, "familyId": value["familyId"], "kind": kind, "occurredAt": time_at(at),
            "capturedAt": time_at(captured), "sourceCommit": p["sourceCommit"], "targetCommit": p["targetCommit"],
            "iteration": p["iteration"], "actorKind": actor, "evidenceRefs": [], "reason": "Synthetic test event."}


class ObserverTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        script, config_file = self.root / "collector.ps1", self.root / "collector.json"
        script.write_text("# fixed trusted test collector\n", encoding="utf-8")
        config_file.write_text("{}", encoding="utf-8")
        self.config = {"schemaVersion": 1, "studyId": "study", "stateRoot": str(self.root),
            "collector": {"scriptPath": str(script), "configPath": str(config_file),
                          "scriptSha256": file_hash(script), "configSha256": file_hash(config_file)},
            "evaluation": {"mode": "offline", "model": "fixture-v1", "fixturePath": str(self.root / "fixture.json"),
                           "runtimePath": None, "deadlineSeconds": 2, "maxAttempts": 1, "maxAiCredits": 30,
                           "dailyLimit": 4, "studyLimit": 5, "exploratory": False},
            "pollSeconds": 30, "maxPages": 3, "maxItems": 25}
        self.ledger = Ledger(self.root, self.config, FROZEN, time_at())
        self.addCleanup(self.ledger.close)
        self.provider = FakeProvider()

    def ingest(self, number=0, value=None, **kwargs):
        request, page = capture(number, value, **kwargs)
        keys = self.ledger.ingest(page, request, FROZEN)
        return keys, page

    async def assess(self, minutes=1, provider=None):
        await assess_pending(self.ledger, self.config, FROZEN,
                             lambda _: provider or self.provider, now=lambda: time_at(minutes))

    def count(self, table):
        return self.ledger.db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    def latest_result(self):
        return report(self.ledger, time_at(12))["latest"][-1]

    def test_config_pins_and_explicit_modes(self):
        validate_config(self.config)
        for mutate in (
            lambda c: c["collector"].update(scriptSha256="b" * 64),
            lambda c: c["evaluation"].update(mode="collection-only"),
            lambda c: c["evaluation"].update(mode="live", model="auto"),
            lambda c: c["evaluation"].update(maxAttempts=3),
            lambda c: c.update(extra="invalid"),
        ):
            changed = copy.deepcopy(self.config)
            mutate(changed)
            with self.subTest(mutate=mutate), self.assertRaises(ContractError):
                validate_config(changed)

    def test_capture_validation_and_label_exclusion(self):
        request, page = capture()
        validate_page(page, request)
        for mutate in (
            lambda p: p["snapshots"][0]["bundle"].update(label=bundle()["label"]),
            lambda p: p["snapshots"].append(copy.deepcopy(p["snapshots"][0])),
            lambda p: p["inventory"][0].update(sourceCommit="b" * 40),
            lambda p: p["snapshots"][0]["observation"].update(capturedAt=time_at(1)),
            lambda p: p["snapshots"][0]["bundle"]["provenance"].update(exportedAt=time_at(1)),
            lambda p: p["page"].update(complete=False),
            lambda p: p.update(captureId="different"),
        ):
            changed = copy.deepcopy(page)
            mutate(changed)
            with self.subTest(mutate=mutate), self.assertRaises(ContractError):
                validate_page(changed, request)

    async def test_collector_can_finish_after_old_300_second_limit(self):
        request, page = capture()
        folder = self.root / "slow-collector"
        folder.mkdir()
        (folder / "response.json").write_text(canonical(page), encoding="utf-8")
        clock = {"elapsed": 0}
        process = Mock(returncode=None)

        async def wait():
            clock["elapsed"] = 400
            process.returncode = 0
            return 0

        @asynccontextmanager
        async def deadline(seconds):
            yield
            if clock["elapsed"] > seconds:
                raise TimeoutError()

        process.wait = AsyncMock(side_effect=wait)
        with patch("observer.asyncio.create_subprocess_exec", AsyncMock(return_value=process)), \
                patch("observer.asyncio.timeout", side_effect=deadline):
            result = await collect_page(self.config, request, folder, self.root, "unused-pwsh", None)
        self.assertEqual(result, page)
        self.assertEqual(COLLECTOR_TIMEOUT_SECONDS, 600 + 60)
        process.kill.assert_not_called()
        self.assertFalse((folder / "collector.interruption.json").exists())

    async def test_collector_timeout_and_cancellation_keep_containment_fail_closed(self):
        for cause, code in ((TimeoutError(), "COLLECTOR_TIMEOUT"),
                            (Cancelled(), "COLLECTOR_CANCELLED"),
                            (asyncio.CancelledError(), "COLLECTOR_CANCELLED")):
            with self.subTest(cause=type(cause).__name__):
                request, _ = capture()
                folder = self.root / type(cause).__name__
                folder.mkdir()
                process = Mock(returncode=None, wait=AsyncMock(return_value=-1))

                @asynccontextmanager
                async def interrupted(seconds):
                    raise cause
                    yield

                with patch("observer.asyncio.create_subprocess_exec", AsyncMock(return_value=process)), \
                        patch("observer.asyncio.timeout", side_effect=interrupted), \
                        self.assertRaisesRegex(CapabilityError, code + "_REQUIRES_CONTAINMENT_CLEANUP"):
                    await collect_page(self.config, request, folder, self.root, "unused-pwsh", None)
                process.kill.assert_called_once()
                process.wait.assert_awaited_once()
                receipt = json.loads((folder / "collector.interruption.json").read_text())
                self.assertEqual(receipt["code"], code)
                self.assertEqual(receipt["timeoutSeconds"], COLLECTOR_TIMEOUT_SECONDS)
                self.assertGreaterEqual(receipt["elapsedSeconds"], 0)
                self.assertEqual(receipt["authorization"], "NONE")
                self.assertFalse((folder / "response.json").exists())

    async def test_interruption_diagnostic_failure_cannot_resume_with_live_collector(self):
        request, _ = capture()
        folder = self.root / "diagnostic-write-failed"
        folder.mkdir()
        process = Mock(returncode=None, wait=AsyncMock(return_value=-1))

        @asynccontextmanager
        async def interrupted(seconds):
            raise TimeoutError()
            yield

        with patch("observer.asyncio.create_subprocess_exec", AsyncMock(return_value=process)), \
                patch("observer.asyncio.timeout", side_effect=interrupted), \
                patch("observer.atomic_write", side_effect=[None, OSError("synthetic disk failure")]), \
                self.assertRaisesRegex(CapabilityError, "DIAGNOSTIC_WRITE_FAILED_REQUIRES_CONTAINMENT_CLEANUP"):
            await collect_page(self.config, request, folder, self.root, "unused-pwsh", None)
        process.kill.assert_called_once()
        process.wait.assert_awaited_once()

    async def test_two_assessments_prospective_not_historical(self):
        self.ingest()
        await self.assess()
        self.assertEqual(self.latest_result()["recommendation"], "APPROVE")
        self.assertEqual(len(self.provider.calls), 2)
        self.assertEqual(self.count("admissions"), 1)
        for prompt, _ in self.provider.calls:
            self.assertNotIn("baselineDecision", prompt)
            self.assertNotIn("outcomes", prompt)
            self.assertNotIn('"label"', prompt)
        result = self.ledger.db.execute("SELECT result FROM decisions").fetchone()[0]
        self.assertIn('"historicalBenchmarkEligible":false', result)
        self.assertIn('"authorization":"NONE"', result)

    async def test_votes_and_capture_timestamps_do_not_trigger_assessments(self):
        self.ingest()
        await self.assess()
        original = self.ledger.db.execute("SELECT * FROM decisions").fetchone()
        for number, state, baseline in ((2, "ACTIVE", "NOT_APPROVED"), (3, "ACTIVE", "APPROVED"),
                                         (4, "COMPLETED", "APPROVED"), (5, "ACTIVE", "NOT_APPROVED")):
            self.ingest(number, state=state, baseline=baseline)
            await self.assess(number)
        self.assertEqual(self.count("snapshots"), 1)
        self.assertEqual(self.count("admissions"), 1)
        self.assertEqual(self.count("decisions"), 1)
        self.assertEqual(tuple(original), tuple(self.ledger.db.execute("SELECT * FROM decisions").fetchone()))
        self.assertEqual(self.ledger.db.execute("SELECT baseline FROM enrollments").fetchone()[0], "NOT_APPROVED")

    async def test_same_commit_evidence_target_and_policy_changes_dedup_correctly(self):
        self.ingest()
        await self.assess()
        changed = bundle()
        changed["evidence"][-1]["content"] += " Additional test coverage."
        self.ingest(2, changed)
        await self.assess(3)
        changed["evidence"][2]["content"] += " Additional required validation."
        self.ingest(4, changed)
        await self.assess(5)
        changed["provenance"]["targetCommit"] = "a" * 40
        for evidence in changed["evidence"]:
            evidence["targetCommit"] = "a" * 40
        self.ingest(6, changed)
        await self.assess(7)
        self.assertEqual(self.count("admissions"), 4)
        self.assertEqual(self.count("snapshots"), 4)

    async def test_guidance_changes_require_new_study(self):
        self.ingest()
        await self.assess()
        changed = bundle()
        changed["guidance"][0]["revision"] = "changed"
        self.ingest(2, changed)
        await self.assess(3)
        self.assertEqual(self.count("admissions"), 1)
        self.assertIn("GUIDANCE_CHANGED_NEW_STUDY_REQUIRED", [g["code"] for g in report(self.ledger, time_at(4))["gaps"]])

    async def test_deterministic_fail_and_missing_policy(self):
        changed = bundle()
        changed["evidence"][-1]["status"] = "FAIL"
        self.ingest(0, changed)
        await self.assess()
        self.assertEqual(self.latest_result()["recommendation"], "REQUEST_CHANGES")
        self.assertEqual(self.count("admissions"), 0)
        changed = bundle()
        changed["completeness"][2].update(status="MISSING", evidenceRefs=[])
        self.ingest(2, changed)
        await self.assess(3)
        self.assertEqual(self.latest_result()["recommendation"], "NEEDS_HUMAN_REVIEW")
        self.assertEqual(len(self.provider.calls), 0)

    async def test_budget_and_orphan_recovery_deadline_and_immutable_rows(self):
        keys, _ = self.ingest()
        self.ledger.admit(keys[0], self.config, time_at())
        self.ledger.recover(time_at(1))
        await self.assess(2)
        self.assertEqual(len(self.provider.calls), 0)
        self.assertEqual(self.ledger.db.execute("SELECT status FROM decisions").fetchone()[0], "INTERRUPTED_UNKNOWN_USAGE")
        self.config["evaluation"]["dailyLimit"] = 1
        self.assertIsNone(self.ledger.admit("next", self.config, time_at(3)))
        self.assertIsNotNone(self.ledger.admit("next-day", self.config, time_at(1440)))
        self.assertIsNone(self.ledger.admit("expired", self.config, time_at(7 * 1440)))
        second = Ledger(self.root, self.config, FROZEN, time_at(100))
        self.assertEqual(second.study["deadline"], self.ledger.study["deadline"])
        second.close()
        with self.assertRaisesRegex(ContractError, "FINGERPRINT_MISMATCH"):
            Ledger(self.root, self.config, "changed", time_at(100))
        with self.assertRaisesRegex(sqlite3.IntegrityError, "immutable"):
            self.ledger.db.execute("DELETE FROM decisions")

    async def test_terminal_and_missing_snapshots_block_queued_inference(self):
        self.ingest()
        request, page = capture(2, state="COMPLETED")
        page["snapshots"] = []
        self.ledger.ingest(page, request, FROZEN)
        await self.assess(3)
        self.assertEqual(self.count("admissions"), 0)
        self.assertEqual(self.latest_result()["status"], "LATEST_OBSERVATION_INELIGIBLE")

    async def test_inventory_only_is_unknown_no_prediction_not_natural(self):
        request, page = capture()
        page["snapshots"] = []
        page["inventory"][0]["isDraft"] = True
        self.ledger.ingest(page, request, FROZEN)
        value = report(self.ledger, time_at(1))
        self.assertEqual(value["cohorts"]["NATURAL"]["families"], 0)
        self.assertEqual(value["cohorts"]["UNKNOWN"]["families"], 1)
        self.assertEqual(value["cohorts"]["UNKNOWN"]["noPrediction"], 1)

    async def test_out_of_order_and_capture_collision(self):
        keys, page = self.ingest(5)
        self.ingest(2)
        await self.assess(6)
        self.assertEqual(self.count("snapshots"), 1)
        request, duplicate = capture(5)
        self.assertEqual(self.ledger.ingest(duplicate, request, FROZEN), [])
        duplicate["gaps"] = [{"code": "different", "familyId": None, "reason": "Different response."}]
        with self.assertRaisesRegex(ContractError, "CAPTURE_ID_COLLISION"):
            self.ledger.ingest(duplicate, request, FROZEN)

    async def test_unknown_enrollment_retains_all_later_decisions_in_its_denominator(self):
        request, page = capture()
        page["snapshots"] = []
        self.ledger.ingest(page, request, FROZEN)
        self.ingest(2)
        await self.assess(3)
        cohorts = report(self.ledger, time_at(4))["cohorts"]
        self.assertEqual(cohorts["UNKNOWN"]["families"], 1)
        self.assertEqual(cohorts["UNKNOWN"]["decisions"], 1)
        self.assertEqual(cohorts["UNKNOWN"]["noPrediction"], 0)
        self.assertEqual(cohorts["SYNTHETIC"]["decisions"], 0)
        self.assertEqual(sum(c["decisions"] for c in cohorts.values()), self.count("decisions"))

    async def test_runtime_no_go_latches_without_more_calls(self):
        class Unavailable(FakeProvider):
            async def assess(self, *args):
                raise CapabilityError("CLEANUP_NOT_CONFIRMED")
        self.ingest()
        await self.assess(provider=Unavailable())
        changed = bundle()
        changed["evidence"][0]["content"] += " New code."
        self.ingest(2, changed)
        await self.assess(3)
        self.assertEqual(len(self.provider.calls), 0)
        self.assertEqual(self.count("admissions"), 1)
        self.assertEqual(self.latest_result()["status"], "MODEL_RUNTIME_BLOCKED")

    async def test_cancel_and_exclusive_owner(self):
        self.ingest()
        cancel = self.root / "cancel"
        cancel.touch()
        with self.assertRaises(Cancelled):
            await assess_pending(self.ledger, self.config, FROZEN, lambda _: self.provider, cancel_file=cancel)
        self.assertEqual(self.count("admissions"), 0)
        with exclusive_output(self.root):
            with self.assertRaises(ContractError):
                with exclusive_output(self.root):
                    pass

    async def test_agreement_is_exact_latest_predecision_live_human_only(self):
        value = bundle()
        value["cohort"] = "NATURAL"
        value["provenance"]["provider"] = "ADO"
        self.config["evaluation"]["mode"] = "live"
        self.ingest(0, value)
        await self.assess(1)
        changed = copy.deepcopy(value)
        changed["evidence"][-1]["status"] = "FAIL"
        self.ingest(2, changed)
        await self.assess(3)
        request, page = capture(11, changed)
        page["outcomes"] = [outcome(value), outcome(value, event_id="completion", kind="COMPLETED"),
                            outcome(value, event_id="bot", actor="AUTOMATION")]
        self.ledger.ingest(page, request, FROZEN)
        result = report(self.ledger, time_at(12))
        self.assertEqual(result["livePolicyAgreement"]["eligible"], 1)
        self.assertEqual(result["livePolicyAgreement"]["matches"][0]["predicted"], "REQUEST_CHANGES")
        self.assertEqual(result["livePolicyAgreement"]["matches"][0]["leadSeconds"], 420)
        request, page = capture(12, changed)
        page["outcomes"] = [outcome(value, event_id="delayed-prior", at=0, captured=12)]
        self.ledger.ingest(page, request, FROZEN)
        self.assertEqual(report(self.ledger, time_at(13))["livePolicyAgreement"]["eligible"], 0)

    async def test_equal_event_time_and_different_target_are_excluded(self):
        value = bundle()
        value["cohort"] = "NATURAL"
        value["provenance"]["provider"] = "ADO"
        self.config["evaluation"]["mode"] = "live"
        self.ingest(0, value)
        await self.assess(1)
        request, page = capture(11, value)
        page["outcomes"] = [outcome(value, at=1)]
        page["outcomes"][0]["occurredAt"] = "2026-01-01T13:01:00+01:00"
        self.ledger.ingest(page, request, FROZEN)
        self.assertEqual(report(self.ledger, time_at(12))["livePolicyAgreement"]["eligible"], 0)

    async def test_report_delivery_and_adjudication_separate_from_model(self):
        self.ingest()
        await self.assess()
        decision = self.ledger.db.execute("SELECT id FROM decisions").fetchone()[0]
        judgment = {"schemaVersion": 1, "id": "human-1", "studyId": "study", "decisionId": decision,
                    "adjudicatedAt": time_at(2), "recommendation": "REQUEST_CHANGES", "evidenceRefs": ["code"],
                    "reason": "Separate operator judgment."}
        import_adjudication(self.ledger, judgment, time_at(3))
        import_adjudication(self.ledger, judgment, time_at(3))
        value = persist_report(self.ledger, time_at(4))
        self.assertEqual(value["livePolicyAgreement"]["eligible"], 0)
        self.assertEqual(len(value["humanAdjudications"]), 1)
        self.assertNotIn("Separate operator judgment", self.provider.calls[0][0])
        delivery = {"schemaVersion": 1, "enabled": False, "privateOperatorDestination": True,
                    "chatId": "19:synthetic@thread.v2", "stateRoot": str(self.root / "outbox"),
                    "studyRoot": str(self.root), "studyId": "study"}
        path = self.root / "delivery.json"
        path.write_text(canonical(delivery), encoding="utf-8")
        immutable = self.root / "reports" / (digest(value) + ".json")
        prepared = prepare(path, immutable)
        self.assertEqual(prepared["reportHash"], digest(value))
        with self.assertRaisesRegex(ContractError, "IMMUTABLE"):
            prepare(path, self.root / "reports" / "latest.json")
        self.assertEqual(self.count("adjudications"), 1)


if __name__ == "__main__":
    unittest.main()
