from __future__ import annotations

import copy
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from test_replay import FakeProvider
from contracts import ContractError, canonical, digest
from observer import Ledger, capture_chunk, persist_report, report
from observer_contracts import validate, validate_page
from replay import Cancelled, CapabilityError
from test_observer import FROZEN, capture, time_at


class SweepTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = {"studyId": "study", "stateRoot": str(self.root), "maxPages": 20, "maxItems": 10,
                       "collector": {"configSha256": "a" * 64},
                       "evaluation": {"mode": "offline", "model": "fixture-v1", "deadlineSeconds": 2,
                                      "maxAttempts": 1, "maxAiCredits": 30, "dailyLimit": 4,
                                      "studyLimit": 5, "exploratory": False}}
        self.ledger = Ledger(self.root, self.config, FROZEN, time_at())
        self.addCleanup(lambda: self.ledger.close())
        self.provider = FakeProvider()
        self.requests = []
        self.size = 235
        self.minutes = 1

    def restart(self):
        self.ledger.close()
        self.ledger = Ledger(self.root, self.config, FROZEN, time_at(self.minutes))

    def count(self, table):
        return self.ledger.db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    def page(self, request, ids, next_cursor=None):
        _, template = capture(self.minutes)
        page = {**template, "captureId": request["captureId"],
                "page": {"cursor": request["cursor"], "nextCursor": next_cursor, "complete": next_cursor is None},
                "inventory": [], "snapshots": []}
        for number in ids:
            inventory = {**template["inventory"][0], "familyId": f"fixture:{number}",
                         "pullRequestId": str(number), "isDraft": number != 235}
            page["inventory"].append(inventory)
            if number == 235:
                snapshot = copy.deepcopy(template["snapshots"][0])
                snapshot["bundle"]["familyId"] = inventory["familyId"]
                snapshot["bundle"]["provenance"]["pullRequestId"] = str(number)
                page["snapshots"].append(snapshot)
        return page

    async def collector(self, config, request, folder, *_args):
        self.requests.append(copy.deepcopy(request))
        if request.get("purpose") == "REFRESH":
            return self.page(request, [int(request["trackedPullRequests"][0]["pullRequestId"])])
        phase, offset = (request["cursor"] or "active:0").split(":")
        offset = int(offset)
        all_ids = list(range(1, self.size + 1)) if phase == "active" else [
            int(item["pullRequestId"]) for item in request["trackedPullRequests"]]
        ids = all_ids[offset:offset + request["maxItems"]]
        next_cursor = f"{phase}:{offset + len(ids)}" if offset + len(ids) < len(all_ids) else (
            "known:0" if phase == "active" and request["trackedPullRequests"] else None)
        return self.page(request, ids, next_cursor)

    async def chunk(self, collector=None):
        with patch("observer.collect_page", side_effect=collector or self.collector):
            return await capture_chunk(self.ledger, self.config, FROZEN, lambda _: self.provider,
                                       self.root, "unused", None, now=lambda: time_at(self.minutes))

    async def test_over_200_active_and_known_resume_same_sweep_and_eventually_assess_fresh_only(self):
        first = await self.chunk()
        self.assertEqual((first["pages"], first["cursor"], first["phase"]), (20, "active:200", "inventory"))
        self.assertEqual(self.count("admissions"), 0)
        self.restart()
        self.minutes = 2
        finished = await self.chunk()
        self.assertEqual(finished["id"], first["id"])
        self.assertEqual((finished["pages"], finished["phase"]), (24, "complete"))
        self.assertEqual(self.count("admissions"), 1)
        self.assertEqual(len(self.provider.calls), 2)
        inventories = [request for request in self.requests if request["purpose"] == "INVENTORY"]
        self.assertTrue(all(request["trackedPullRequests"] == [] for request in inventories))
        self.assertEqual({request["startedAt"] for request in inventories}, {time_at(1)})
        self.assertEqual(self.requests[-1]["purpose"], "REFRESH")
        self.assertEqual(self.requests[-1]["trackedPullRequests"], [{"familyId": "fixture:235", "pullRequestId": "235"}])
        decision = dict(self.ledger.db.execute("SELECT * FROM decisions").fetchone())
        self.assertEqual(json.loads(decision["result"])["authorization"], "NONE")
        self.assertEqual(json.loads(decision["result"])["recommendation"], "APPROVE")
        self.minutes = 3
        second = await self.chunk()
        self.assertNotEqual(second["id"], first["id"])
        self.assertEqual(second["pages"], 20)
        self.restart()
        self.minutes = 4
        second = await self.chunk()
        self.assertEqual((second["pages"], second["cursor"]), (40, "known:160"))
        self.assertEqual(self.count("admissions"), 1)
        self.restart()
        second = await self.chunk()
        self.assertEqual((second["pages"], second["phase"]), (48, "complete"))
        self.assertEqual(self.count("snapshots"), 1)
        self.assertEqual(self.count("admissions"), 1)
        self.assertEqual(dict(self.ledger.db.execute("SELECT * FROM decisions").fetchone()), decision)
        self.assertEqual(len(self.provider.calls), 2)
        self.assertTrue(any(request["cursor"] == "known:230" for request in self.requests))

    async def test_finite_growth_continues_from_offset_not_zero(self):
        await self.chunk()
        self.size = 245
        self.restart()
        result = await self.chunk()
        self.assertEqual((result["pages"], result["phase"]), (25, "complete"))
        self.assertEqual(self.requests[20]["cursor"], "active:200")
        self.assertEqual(self.count("enrollments"), 245)

    async def test_capture_failures_retry_same_cursor_with_new_receipts_then_block(self):
        self.config["maxPages"] = 1
        state = await self.chunk()
        for failures in range(1, 4):
            self.restart()
            state = await self.chunk(AsyncMock(side_effect=ContractError("COLLECTOR_EXIT_42")))
            self.assertEqual(state["cursor"], "active:10")
            self.assertEqual(state["failures"], failures)
            self.assertEqual(report(self.ledger, time_at(2))["collection"]["collectionStatus"],
                             "blocked" if failures == 3 else "capture_failed")
        unused = AsyncMock()
        await self.chunk(unused)
        unused.assert_not_called()
        self.assertEqual(self.count("sweep_attempts"), 4)
        self.assertEqual(self.count("admissions"), 0)

    async def test_guidance_drift_blocks_immediately_without_retry(self):
        self.size = 1

        async def eligible(config, request, folder, *args):
            page = await self.collector(config, request, folder, *args)
            for inventory in page["inventory"]:
                inventory["isDraft"] = False
                if not page["snapshots"]:
                    _, template = capture(self.minutes)
                    snapshot = copy.deepcopy(template["snapshots"][0])
                    snapshot["bundle"]["familyId"] = inventory["familyId"]
                    snapshot["bundle"]["provenance"]["pullRequestId"] = inventory["pullRequestId"]
                    page["snapshots"].append(snapshot)
            return page

        first = await self.chunk(eligible)
        self.assertEqual(first["phase"], "complete")
        self.assertEqual(self.count("admissions"), 1)
        self.restart()
        self.minutes = 2

        async def drifting(config, request, folder, *args):
            page = await eligible(config, request, folder, *args)
            if page["snapshots"]:
                page["snapshots"][0]["bundle"]["guidance"][0]["revision"] = "changed"
            return page

        state = await self.chunk(drifting)
        self.assertEqual((state["phase"], state["reason"], state["failures"]),
                         ("blocked", "GUIDANCE_CHANGED_NEW_STUDY_REQUIRED", 0))
        self.assertEqual(self.count("admissions"), 1)
        value = report(self.ledger, time_at(3))
        self.assertIn("GUIDANCE_CHANGED_NEW_STUDY_REQUIRED", value["admissionBlockers"])
        self.assertIn("GUIDANCE_CHANGED_NEW_STUDY_REQUIRED", [item["code"] for item in value["gaps"]])

    async def test_accepted_page_survives_precommit_crash_without_recollection(self):
        self.config["maxPages"] = 1

        async def accepted(config, request, folder, *args):
            page = await self.collector(config, request, folder, *args)
            (folder / "response.json").write_text(canonical(page))
            (folder / "accepted.json").write_text(canonical({"requestHash": digest(request), "pageHash": digest(page)}))
            return page

        with patch.object(self.ledger, "ingest", side_effect=RuntimeError("synthetic crash")):
            with self.assertRaisesRegex(RuntimeError, "synthetic crash"):
                await self.chunk(accepted)
        self.restart()
        unused = AsyncMock()
        state = await self.chunk(unused)
        unused.assert_not_called()
        self.assertEqual((state["cursor"], self.count("captures")), ("active:10", 1))
        self.assertEqual(self.count("sweep_attempts"), 1)

    async def test_corrupt_accepted_receipt_is_rejected_without_new_collection(self):
        self.config["maxPages"] = 1

        async def accepted(config, request, folder, *args):
            page = await self.collector(config, request, folder, *args)
            (folder / "response.json").write_text(canonical(page))
            (folder / "accepted.json").write_text(canonical({"requestHash": digest(request), "pageHash": "bad"}))
            return page

        with patch.object(self.ledger, "ingest", side_effect=RuntimeError("synthetic crash")):
            with self.assertRaises(RuntimeError):
                await self.chunk(accepted)
        self.restart()
        unused = AsyncMock()
        with self.assertRaisesRegex(ContractError, "SWEEP_RECEIPT_MISMATCH"):
            await self.chunk(unused)
        unused.assert_not_called()
        self.assertEqual(self.count("captures"), 0)

    async def test_crash_after_ingest_commits_cursor_and_never_reuses_refresh_after_crash(self):
        self.size = 235
        self.config["maxPages"] = 24
        state = await self.chunk()
        self.assertEqual(state["phase"], "refresh")
        with patch("observer.assess_pending", side_effect=RuntimeError("crash before inference")):
            with self.assertRaisesRegex(RuntimeError, "crash before inference"):
                await self.chunk()
        old_refresh = self.requests[-1]
        self.restart()
        self.minutes = 2
        state = await self.chunk()
        self.assertEqual(state["phase"], "complete")
        self.assertNotEqual(self.requests[-1]["captureId"], old_refresh["captureId"])
        self.assertEqual(self.requests[-1]["startedAt"], time_at(2))
        self.assertEqual(self.count("admissions"), 1)
        self.assertEqual(len(self.provider.calls), 2)

    async def test_loop_empty_terminal_and_truncation_are_not_false_completion(self):
        self.config["maxPages"] = 1

        async def looping(config, request, *_args):
            return self.page(request, [], "loop")

        state = await self.chunk(looping)
        self.assertEqual(state["phase"], "inventory")
        state = await self.chunk(looping)
        self.assertEqual((state["phase"], state["reason"]), ("blocked", "PAGINATION_CYCLE"))
        self.assertEqual(self.count("admissions"), 0)
        with self.assertRaises(sqlite3.IntegrityError):
            self.ledger.db.execute("DELETE FROM sweep_progress")

    async def test_repeated_membership_and_page_limit_block_even_with_new_cursors(self):
        calls = 0

        async def advancing(config, request, *_args):
            nonlocal calls
            calls += 1
            return self.page(request, [], f"offset:{calls}")

        state = await self.chunk(advancing)
        self.assertEqual((state["phase"], state["reason"]), ("blocked", "PAGINATION_NO_PROGRESS"))
        self.assertEqual(calls, 4)
        self.assertEqual(self.count("admissions"), 0)

    async def test_page_limit_is_a_block_not_terminal_completion(self):
        with patch("observer.MAX_SWEEP_PAGES", 2):
            state = await self.chunk()
        self.assertEqual((state["phase"], state["reason"], state["pages"]),
                         ("blocked", "PAGINATION_PAGE_LIMIT", 2))
        self.assertEqual(self.count("admissions"), 0)

    async def test_empty_terminal_inventory_is_complete_without_any_inference(self):
        self.size = 0
        state = await self.chunk()
        self.assertEqual(state["phase"], "complete")
        self.assertEqual(self.count("snapshots"), 0)
        self.assertEqual(self.count("admissions"), 0)

    async def test_empty_terminal_after_empty_continuations_is_still_explicit_completion(self):
        calls = 0

        async def empty(config, request, *_args):
            nonlocal calls
            calls += 1
            return self.page(request, [], None if calls == 4 else f"offset:{calls}")

        state = await self.chunk(empty)
        self.assertEqual((state["phase"], state["pages"]), ("complete", 4))
        self.assertEqual(self.count("admissions"), 0)

    async def test_refresh_missing_terminal_or_changed_heads_cannot_admit_old_snapshot(self):
        self.config["maxPages"] = 24
        await self.chunk()

        async def unavailable(config, request, *_args):
            page = self.page(request, [235])
            page["inventory"][0]["state"] = "COMPLETED"
            page["snapshots"] = []
            return page

        state = await self.chunk(unavailable)
        self.assertEqual(state["phase"], "complete")
        self.assertEqual(self.count("admissions"), 0)
        self.assertEqual(len(self.provider.calls), 0)
        self.assertEqual(report(self.ledger, time_at(2))["snapshots"], 1)

    async def test_changed_target_refresh_evaluates_only_fresh_version_and_persists_current_input(self):
        self.config["maxPages"] = 24
        await self.chunk()
        old_key = self.ledger.db.execute("SELECT key FROM snapshots").fetchone()[0]
        self.minutes = 2

        async def changed(config, request, *_args):
            page = self.page(request, [235])
            page["inventory"][0]["targetCommit"] = "c" * 40
            value = page["snapshots"][0]["bundle"]
            value["provenance"]["targetCommit"] = "c" * 40
            for evidence in value["evidence"]:
                evidence["targetCommit"] = "c" * 40
            return page

        await self.chunk(changed)
        decisions = [dict(row) for row in self.ledger.db.execute("SELECT * FROM decisions")]
        self.assertEqual(next(row for row in decisions if row["snapshot"] == old_key)["status"], "SUPERSEDED_BEFORE_ASSESSMENT")
        completed = next(row for row in decisions if row["status"] == "COMPLETED")
        self.assertEqual(json.loads(completed["result"])["provenance"]["targetCommit"], "c" * 40)
        self.assertEqual(json.loads(completed["result"])["provenance"]["cutoff"], time_at(2))
        self.assertEqual(self.count("admissions"), 1)
        self.assertEqual(len(self.provider.calls), 2)
        context = json.loads(self.ledger.db.execute("SELECT payload FROM decision_context WHERE id=?", (completed["id"],)).fetchone()[0])
        self.assertEqual(context["provenance"]["cutoff"], time_at(2))

    async def test_unchanged_refresh_uses_current_baseline_and_cutoff_without_rewriting_snapshot(self):
        self.config["maxPages"] = 24
        await self.chunk()
        original = dict(self.ledger.db.execute("SELECT * FROM snapshots").fetchone())
        self.minutes = 2

        async def unknown_baseline(config, request, *_args):
            page = self.page(request, [235])
            page["snapshots"][0]["observation"]["baselineDecision"] = "UNKNOWN"
            return page

        await self.chunk(unknown_baseline)
        self.assertEqual(dict(self.ledger.db.execute("SELECT * FROM snapshots").fetchone()), original)
        context = dict(self.ledger.db.execute("SELECT * FROM decision_context").fetchone())
        self.assertEqual(json.loads(context["observation"])["baselineDecision"], "UNKNOWN")
        self.assertEqual(json.loads(context["payload"])["provenance"]["cutoff"], time_at(2))

    async def test_missing_refresh_never_reuses_stored_snapshot(self):
        self.config["maxPages"] = 24
        await self.chunk()

        async def missing(config, request, *_args):
            return self.page(request, [])

        await self.chunk(missing)
        self.assertEqual(self.count("admissions"), 0)
        self.assertEqual(self.count("decisions"), 0)
        self.assertIn("REFRESH_UNAVAILABLE", [row["code"] for row in report(self.ledger, time_at(2))["gaps"]])

    async def test_refresh_cannot_evaluate_a_different_queued_family(self):
        request, page = capture()
        self.ledger.ingest(page, request, FROZEN)
        untouched = page["inventory"][0]["familyId"]
        self.config["maxPages"] = 24
        await self.chunk()
        await self.chunk()
        self.assertEqual(self.count("admissions"), 1)
        self.assertFalse(self.ledger.db.execute(
            "SELECT 1 FROM decisions d JOIN snapshots s ON s.key=d.snapshot WHERE s.family=?", (untouched,)).fetchone())

    async def test_refresh_age_and_deadline_cancel_never_allow_inference(self):
        self.config["maxPages"] = 24
        await self.chunk()

        async def aged(config, request, folder, *args):
            page = await self.collector(config, request, folder, *args)
            self.minutes += 6
            return page

        state = await self.chunk(aged)
        self.assertEqual(state["phase"], "complete")
        self.assertEqual(self.count("admissions"), 0)
        self.assertIn("REFRESH_EXPIRED", [item["code"] for item in report(self.ledger, time_at(10))["gaps"]])
        self.minutes = 7 * 24 * 60
        unused = AsyncMock()
        await self.chunk(unused)
        unused.assert_not_called()
        with patch("observer.is_cancelled", side_effect=Cancelled):
            with self.assertRaises(Cancelled):
                await self.chunk(unused)

    async def test_interrupted_collector_preserves_cursor_and_blocks_repeated_timeouts(self):
        self.config["maxPages"] = 1
        await self.chunk()
        for _ in range(3):
            with self.assertRaisesRegex(CapabilityError, "COLLECTOR_TIMEOUT"):
                await self.chunk(AsyncMock(side_effect=CapabilityError("COLLECTOR_TIMEOUT_REQUIRES_CONTAINMENT_CLEANUP")))
            self.restart()
        self.assertEqual(self.ledger.progress()["phase"], "blocked")
        self.assertEqual(self.ledger.progress()["cursor"], "active:10")

    def test_refresh_contract_closed_scope_current_capture_and_immutable_fingerprint(self):
        request, page = capture(1)
        request.update(purpose="REFRESH", maxItems=1, trackedPullRequests=[
            {"familyId": page["inventory"][0]["familyId"], "pullRequestId": page["inventory"][0]["pullRequestId"]}])
        validate_page(page, request)
        for key, value in (("purpose", "OTHER"), ("cursor", "known:0"), ("maxItems", 2), ("trackedPullRequests", [])):
            with self.subTest(key=key), self.assertRaises(ContractError):
                validate({**request, key: value}, "observation-request")
        for change in ("other-family", "not-terminal", "old-cutoff"):
            changed = copy.deepcopy(page)
            if change == "other-family":
                changed["inventory"][0]["familyId"] = "unrequested"
            elif change == "not-terminal":
                changed["page"].update(complete=False, nextCursor="next")
            else:
                changed["snapshots"][0]["bundle"]["provenance"]["cutoff"] = time_at()
            with self.subTest(change=change), self.assertRaises(ContractError):
                validate_page(changed, request)
        with self.assertRaisesRegex(ContractError, "FINGERPRINT_MISMATCH"):
            Ledger(self.root, self.config, "different", time_at(2))

    def test_old_study_rejected_before_any_schema_or_journal_mutation(self):
        old = self.root / "legacy"
        old.mkdir()
        with closing(sqlite3.connect(old / "observer.sqlite")) as db:
            db.execute("CREATE TABLE study(id TEXT, frozen TEXT)")
            db.execute("INSERT INTO study VALUES('study','old-engine')")
            db.commit()
        before = (old / "observer.sqlite").read_bytes()
        with self.assertRaisesRegex(ContractError, "FINGERPRINT_MISMATCH"):
            Ledger(old, self.config, FROZEN, time_at(2))
        self.assertEqual((old / "observer.sqlite").read_bytes(), before)
        self.assertEqual([path.name for path in old.iterdir()], ["observer.sqlite"])

    async def test_report_distinguishes_pending_snapshots_from_no_decisions(self):
        self.config["maxPages"] = 24
        await self.chunk()
        value = persist_report(self.ledger, time_at(2))
        self.assertEqual((value["snapshots"], value["decisions"], value["admissions"]), (1, 0, 0))
        self.assertEqual(value["collection"]["collectionStatus"], "reconciling")
        self.assertIn("FRESH_RECONCILIATION_PENDING", value["admissionBlockers"])
        self.assertIn("Stored snapshots: 1; decisions: 0", (self.root / "reports" / "latest.md").read_text())


if __name__ == "__main__":
    unittest.main()
