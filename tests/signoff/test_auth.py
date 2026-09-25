from __future__ import annotations

import asyncio
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import sys
import tempfile
import traceback
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

from test_replay import REPO, bundle
from contracts import canonical
from observer import worker
from observer_contracts import file_hash
from replay import CapabilityError, evaluate
from sdk_adapter import (SdkProvider, TOKEN_OVERRIDE, gh_auth_environment, isolated_environment,
                         resolve_gh_path, resolve_github_token)
from signoff_replay import main_async, parser


class FakeProcess:
    def __init__(self, output=b"gho_test_secret\n", code=0, *, hang=False):
        self.stdout = asyncio.StreamReader()
        self.stdout.feed_data(output)
        if not hang:
            self.stdout.feed_eof()
        self.returncode = None
        self.code = code
        self.killed = False

    async def wait(self):
        self.returncode = self.code
        return self.code

    def kill(self):
        self.killed = True
        self.returncode = -9


class CredentialTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    async def test_dedicated_override_preserved_and_exclusive(self):
        with patch.dict(os.environ, {TOKEN_OVERRIDE: "ghu_explicit_secret"}, clear=True), \
                patch("sdk_adapter.resolve_gh_path", side_effect=AssertionError("must not resolve gh")), \
                patch("sdk_adapter.asyncio.create_subprocess_exec", new_callable=AsyncMock) as launch:
            self.assertEqual(await resolve_github_token(self.root), "ghu_explicit_secret")
            launch.assert_not_called()

    async def test_empty_or_invalid_explicit_override_never_falls_back(self):
        for value in ("", " ", "bad\nsecond", "\t", "secret" * 2000):
            with self.subTest(value_length=len(value)), \
                    patch.dict(os.environ, {TOKEN_OVERRIDE: value}, clear=True), \
                    patch("sdk_adapter.asyncio.create_subprocess_exec", new_callable=AsyncMock) as launch:
                with self.assertRaisesRegex(CapabilityError, "EXPLICIT_TOKEN_EMPTY_OR_MALFORMED"):
                    await resolve_github_token(self.root)
                launch.assert_not_called()

    async def test_existing_login_uses_fixed_native_gh_memory_only_and_sanitized_environment(self):
        native = self.root / "installed" / "gh.exe"
        process = FakeProcess()
        ambient = {"HOME": str(self.root), "GH_HOST": "attacker.invalid", "GH_DEBUG": "api",
                   "COPILOT_GITHUB_TOKEN": "must_not_be_used", "GH_CONFIG_DIR": "untrusted",
                   "HTTPS_PROXY": "untrusted", "OPENAI_API_KEY": "byok"}
        output, errors = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, ambient, clear=True), \
                patch("sdk_adapter.resolve_gh_path", return_value=native), \
                patch("sdk_adapter.asyncio.create_subprocess_exec", AsyncMock(return_value=process)) as launch, \
                redirect_stdout(output), redirect_stderr(errors):
            token = await resolve_github_token(self.root)
        self.assertEqual(token, "gho_test_secret")
        self.assertEqual(launch.call_args.args, (str(native), "auth", "token", "--hostname", "github.com"))
        options = launch.call_args.kwargs
        self.assertFalse(options.get("shell", False))
        self.assertEqual(options["cwd"], self.root)
        self.assertEqual(options["stderr"], asyncio.subprocess.DEVNULL)
        self.assertEqual(options["stdin"], asyncio.subprocess.DEVNULL)
        for name in ("GH_HOST", "GH_DEBUG", "GH_CONFIG_DIR", "COPILOT_GITHUB_TOKEN", "HTTPS_PROXY", "OPENAI_API_KEY"):
            self.assertNotIn(name, options["env"])
        self.assertNotIn(token, repr(launch.call_args))
        self.assertEqual(output.getvalue() + errors.getvalue(), "")
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertNotIn(token, canonical(isolated_environment(self.root)))

    def test_gh_standard_token_precedence_delegated_without_host_or_account_selection(self):
        with patch.dict(os.environ, {"GH_TOKEN": "gho_first", "GITHUB_TOKEN": "gho_second",
                                     TOKEN_OVERRIDE: "private_override", "GH_HOST": "enterprise.invalid"}, clear=True):
            env = gh_auth_environment()
        self.assertEqual(env["GH_TOKEN"], "gho_first")
        self.assertEqual(env["GITHUB_TOKEN"], "gho_second")
        self.assertNotIn(TOKEN_OVERRIDE, env)
        self.assertNotIn("GH_HOST", env)
        self.assertEqual(env["GH_PROMPT_DISABLED"], "1")

    async def test_missing_auth_and_malformed_or_oversize_output_fail_redacted(self):
        for output, code in ((b"gho_rejected_secret\n", 1), (b"", 0), (b"one\ntwo\n", 0),
                             (b"\xffsensitive", 0), (b"x" * 8193, 0)):
            process = FakeProcess(output, code)
            with self.subTest(code=code, length=len(output)), patch.dict(os.environ, {}, clear=True), \
                    patch("sdk_adapter.resolve_gh_path", return_value=self.root / "gh.exe"), \
                    patch("sdk_adapter.asyncio.create_subprocess_exec", AsyncMock(return_value=process)) as launch:
                try:
                    await resolve_github_token(self.root)
                    self.fail("must fail")
                except CapabilityError as error:
                    rendered = "".join(traceback.format_exception(error))
                    self.assertNotIn("rejected_secret", rendered)
                    self.assertNotIn("sensitive", rendered)
                    self.assertNotIn("one\ntwo", rendered)
                self.assertEqual(launch.await_count, 1)

    async def test_timeout_and_cancellation_kill_gh_before_returning(self):
        for cancel in (False, True):
            process = FakeProcess(b"gho_partial_secret", hang=True)
            with self.subTest(cancel=cancel), patch.dict(os.environ, {}, clear=True), \
                    patch("sdk_adapter.AUTH_TIMEOUT_SECONDS", 0.02), \
                    patch("sdk_adapter.resolve_gh_path", return_value=self.root / "gh.exe"), \
                    patch("sdk_adapter.asyncio.create_subprocess_exec", AsyncMock(return_value=process)):
                if cancel:
                    task = asyncio.create_task(resolve_github_token(self.root))
                    await asyncio.sleep(0)
                    task.cancel()
                    with self.assertRaises(asyncio.CancelledError):
                        await task
                else:
                    with self.assertRaisesRegex(CapabilityError, "GH_AUTH_DEADLINE"):
                        await resolve_github_token(self.root)
            self.assertTrue(process.killed)
            self.assertIsNotNone(process.returncode)

    async def test_gh_launch_failure_has_no_secret_exception_chain(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch("sdk_adapter.resolve_gh_path", return_value=self.root / "gh.exe"), \
                patch("sdk_adapter.asyncio.create_subprocess_exec", AsyncMock(side_effect=OSError("secret-output"))):
            with self.assertRaisesRegex(CapabilityError, "GH_AUTH_PROCESS_UNAVAILABLE") as caught:
                await resolve_github_token(self.root)
            self.assertNotIn("secret-output", "".join(traceback.format_exception(caught.exception)))

    def test_native_path_resolution_excludes_cwd_relative_paths_checkout_and_links(self):
        name = "gh.exe" if os.name == "nt" else "gh"
        installed = self.root / "installed"
        installed.mkdir()
        executable = installed / name
        executable.touch()
        executable.chmod(0o700)
        with patch("sdk_adapter.os.get_exec_path", return_value=["", ".", "relative", str(installed)]):
            self.assertEqual(resolve_gh_path(), executable.resolve())
        with patch("sdk_adapter.os.get_exec_path", return_value=[str(installed)]), \
                patch("sdk_adapter.Path.cwd", return_value=installed):
            with self.assertRaisesRegex(CapabilityError, "OUTSIDE_CHECKOUT"):
                resolve_gh_path()
        (self.root / ".git").mkdir()
        with patch("sdk_adapter.os.get_exec_path", return_value=[str(installed)]):
            with self.assertRaisesRegex(CapabilityError, "OUTSIDE_CHECKOUT"):
                resolve_gh_path()
        (self.root / ".git").rmdir()
        with patch("sdk_adapter.os.get_exec_path", return_value=[str(installed)]), \
                patch("sdk_adapter.Path.is_symlink", return_value=True):
            with self.assertRaisesRegex(CapabilityError, "LINK_NOT_ALLOWED"):
                resolve_gh_path()
        with patch("sdk_adapter.os.get_exec_path", return_value=[".", "relative"]):
            with self.assertRaisesRegex(CapabilityError, "GH_NOT_FOUND"):
                resolve_gh_path()

    async def test_sdk_rejected_explicit_token_does_not_change_account_or_relax_isolation(self):
        runtime = self.root / "copilot-runtime.exe"
        runtime.touch()
        (self.root / "runtime.node").touch()
        client = SimpleNamespace(start=AsyncMock(), stop=AsyncMock(), force_stop=AsyncMock(),
            get_status=AsyncMock(return_value=SimpleNamespace(version="1.0.85")),
            get_auth_status=AsyncMock(return_value=SimpleNamespace(isAuthenticated=False)),
            create_session=AsyncMock(), list_models=AsyncMock())
        constructor = Mock(return_value=client)
        fake_sdk = SimpleNamespace(CopilotClient=constructor, RuntimeConnection=SimpleNamespace(for_stdio=Mock()))
        with patch.dict(os.environ, {TOKEN_OVERRIDE: "gho_invalid_secret"}, clear=True), \
                patch.dict(sys.modules, {"copilot": fake_sdk, "copilot.session_events": SimpleNamespace(AssistantUsageData=type("Usage", (), {}))}), \
                patch("sdk_adapter.require_containment"), patch("sdk_adapter.importlib.metadata.version", return_value="1.0.14"), \
                patch("sdk_adapter.asyncio.create_subprocess_exec", new_callable=AsyncMock) as gh:
            provider = SdkProvider(runtime, "explicit-model", 30)
            self.assertIsNone(provider.token)
            with self.assertRaisesRegex(CapabilityError, "LIVE_NO_GO_AUTHENTICATION"):
                await provider.assess(bundle(), "data-only", 0)
            gh.assert_not_called()
        kwargs = constructor.call_args.kwargs
        self.assertEqual(kwargs["github_token"], "gho_invalid_secret")
        self.assertFalse(kwargs["use_logged_in_user"])
        self.assertEqual(kwargs["mode"], "empty")
        self.assertEqual(kwargs["builtin_plugin_directories"], [])
        self.assertFalse(kwargs["enable_remote_sessions"])
        self.assertNotIn("gho_invalid_secret", canonical(kwargs["env"]))
        self.assertNotIn("GH_TOKEN", kwargs["env"])
        client.list_models.assert_not_awaited()
        client.create_session.assert_not_awaited()
        client.stop.assert_awaited_once()

    async def test_deterministic_abstention_never_resolves_credentials(self):
        runtime = self.root / "copilot-runtime.exe"
        runtime.touch()
        (self.root / "runtime.node").touch()
        value = bundle()
        value["completeness"][2].update(status="MISSING", evidenceRefs=[])
        with patch("sdk_adapter.require_containment"), patch("sdk_adapter.importlib.metadata.version", return_value="1.0.14"), \
                patch("sdk_adapter.resolve_github_token", new_callable=AsyncMock) as auth:
            provider = SdkProvider(runtime, "explicit-model", 30)
            result = await evaluate(value, provider, 1, 1)
            self.assertEqual(result["recommendation"], "NEEDS_HUMAN_REVIEW")
            auth.assert_not_awaited()

    async def test_offline_and_bundle_validation_never_resolve_credentials(self):
        with patch("sdk_adapter.resolve_github_token", new_callable=AsyncMock) as auth, redirect_stdout(io.StringIO()):
            self.assertEqual(await main_async(parser().parse_args([
                "validate-bundle", "--input", str(REPO / "samples" / "signoff" / "complete.bundle.json")])), 0)
            self.assertEqual(await main_async(parser().parse_args([
                "run", "--mode", "offline", "--input", str(REPO / "samples" / "signoff" / "complete.bundle.json"),
                "--fixtures", str(REPO / "samples" / "signoff" / "responses.json"),
                "--model", "fixture-v1", "--output-root", str(self.root / "offline")])), 0)
            auth.assert_not_awaited()

    async def test_live_validate_only_does_not_resolve_auth_or_discover_models(self):
        config_file = self.root / "collector.json"
        script = self.root / "collector.ps1"
        config_file.write_text("{}", encoding="utf-8")
        script.write_text("# synthetic collector", encoding="utf-8")
        config = {"schemaVersion": 1, "studyId": "auth-validation", "stateRoot": str(self.root / "state"),
                  "collector": {"scriptPath": str(script), "configPath": str(config_file),
                                "scriptSha256": file_hash(script), "configSha256": file_hash(config_file)},
                  "evaluation": {"mode": "live", "model": "explicit-model", "fixturePath": None,
                                 "runtimePath": str(self.root / "runtime.exe"), "deadlineSeconds": 60,
                                 "maxAttempts": 1, "maxAiCredits": 30, "dailyLimit": 1, "studyLimit": 1, "exploratory": False},
                  "pollSeconds": 30, "maxPages": 1, "maxItems": 1}
        path = self.root / "study.json"
        path.write_text(canonical(config), encoding="utf-8")
        with patch("observer.NoModelProvider.assess", new_callable=AsyncMock) as model, \
                patch("sdk_adapter.resolve_github_token", new_callable=AsyncMock) as auth, \
                patch("sdk_adapter.SdkProvider", side_effect=AssertionError("no SDK probe")), redirect_stdout(io.StringIO()):
            self.assertEqual(await worker(SimpleNamespace(config=path, enable_model=True, validate_only=True)), 0)
            auth.assert_not_awaited()
            model.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
