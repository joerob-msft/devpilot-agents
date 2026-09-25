"""Pinned official SDK adapter. No CLI-output inference, implicit installs, or auth fallback."""

from __future__ import annotations

import asyncio
import ctypes
import hashlib
import importlib.metadata
import logging
import math
import os
from pathlib import Path
import tempfile
from typing import Any

from contracts import SYSTEM_PROMPT, digest
from replay import AssessmentFailure, CapabilityError

SDK_VERSION = "1.0.14"
RUNTIME_VERSION = "1.0.85"
DISABLED_MCP_SERVERS = ["github", "github-mcp-server"]


def deny_permission(_request: Any, _invocation: Any) -> Any:
    from copilot.generated.rpc import PermissionDecisionReject
    return PermissionDecisionReject(feedback="Read-only replay: all permissions denied.")


def session_options(model: str, directory: Path, credits: float) -> dict[str, Any]:
    return {
        "model": model, "on_permission_request": deny_permission,
        "system_message": {"mode": "replace", "content": SYSTEM_PROMPT},
        "available_tools": [], "tools": [], "mcp_servers": {}, "custom_agents": [],
        "disabled_mcp_servers": DISABLED_MCP_SERVERS,
        "hooks": {}, "working_directory": str(directory), "additional_directories": [],
        "config_directory": str(directory / "config"), "enable_config_discovery": False,
        "skip_custom_instructions": True, "organization_custom_instructions": "",
        "custom_agents_local_only": True, "coauthor_enabled": False, "manage_schedule_enabled": False,
        "enable_session_telemetry": False, "enable_citations": False,
        "enable_file_change_tracking": False, "enable_experimental_mode": False,
        "enable_file_hooks": False, "enable_host_git_operations": False,
        "enable_session_store": False, "enable_skills": False,
        "included_builtin_skills": [], "skill_directories": [], "plugin_directories": [],
        "instruction_directories": [], "enable_on_demand_instruction_discovery": False,
        "skip_embedding_retrieval": True, "embedding_cache_storage": "in-memory",
        "mcp_oauth_token_storage": "in-memory", "request_extensions": False,
        "request_canvas_renderer": False, "canvases": [], "enable_mcp_apps": False,
        "memory": {"enabled": False}, "infinite_sessions": {"enabled": False},
        "tool_search": {"enabled": False}, "large_output": {"enabled": False},
        "session_limits": {"max_ai_credits": credits},
    }


def isolated_environment(directory: Path) -> dict[str, str]:
    # No inherited tool, MCP, session, credential, proxy, provider or injection environment.
    env = {key: os.environ[key] for key in ("SystemRoot", "WINDIR", "COMSPEC") if key in os.environ}
    for name in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TMP", "TEMP", "COPILOT_HOME"):
        path = directory / name.lower()
        path.mkdir()
        env[name] = str(path)
    env["COPILOT_SKIP_CLI_DOWNLOAD"] = "1"
    return env


def require_containment() -> None:
    if os.name != "nt":
        raise CapabilityError("LIVE_REQUIRES_WINDOWS_CONTAINMENT_WRAPPER")
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.IsProcessInJob.argtypes = [wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)]
    contained = wintypes.BOOL()
    if not kernel.IsProcessInJob(kernel.GetCurrentProcess(), None, ctypes.byref(contained)) or not contained.value:
        raise CapabilityError("LIVE_REQUIRES_Invoke-SignoffReplay_JOB_CONTAINMENT")


def runtime_fingerprint(path: Path) -> str:
    files = {}
    for item in sorted(path.parent.rglob("*")):
        if item.is_symlink():
            raise CapabilityError("RUNTIME_SYMLINK_NOT_ALLOWED")
        if item.is_file():
            with item.open("rb") as stream:
                files[str(item.relative_to(path.parent))] = hashlib.file_digest(stream, "sha256").hexdigest()
    return digest(files)


async def verify_session(session: Any, model: str) -> None:
    await session.rpc.tools.initialize_and_validate()
    metadata = await session.rpc.tools.get_current_metadata()
    if metadata.tools != []:
        raise CapabilityError("LIVE_NO_GO_EFFECTIVE_TOOLS_NOT_EMPTY")
    if (await session.rpc.plugins.list()).plugins:
        raise CapabilityError("LIVE_NO_GO_PLUGINS_PRESENT")
    if (await session.rpc.extensions.list()).extensions:
        raise CapabilityError("LIVE_NO_GO_EXTENSIONS_PRESENT")
    servers = (await session.rpc.mcp.list()).servers
    if any(server.name not in DISABLED_MCP_SERVERS or server.status.value != "disabled" for server in servers):
        raise CapabilityError("LIVE_NO_GO_MCP_SERVERS_NOT_DISABLED")
    if (await session.rpc.model.get_current()).model_id != model:
        raise CapabilityError("LIVE_NO_GO_MODEL_SELECTION_MISMATCH")


class SdkProvider:
    def __init__(self, runtime: Path, model: str, credits: float):
        require_containment()
        try:
            installed = importlib.metadata.version("github-copilot-sdk")
        except importlib.metadata.PackageNotFoundError as error:
            raise CapabilityError("INSTALL_requirements-live.txt_OUTSIDE_EVALUATION") from error
        if installed != SDK_VERSION:
            raise CapabilityError("SDK_VERSION_MISMATCH_REQUIRES_1.0.14")
        if not math.isfinite(credits) or not 30 <= credits <= 100:
            raise CapabilityError("RUNTIME_REQUIRES_AI_CREDIT_LIMIT_30_TO_100")
        self.runtime = runtime.resolve()
        if not self.runtime.is_file() or not (self.runtime.parent / "runtime.node").is_file():
            raise CapabilityError("PREPROVISION_PINNED_RUNTIME_1.0.85_OUTSIDE_EVALUATION")
        self.token = os.environ.get("DEVPILOT_SIGNOFF_GITHUB_TOKEN")
        if not self.token:
            raise CapabilityError("SET_DEVPILOT_SIGNOFF_GITHUB_TOKEN_WITH_COPILOT_ENTITLEMENT")
        self.model = model
        self.credits = credits
        self.metadata = {
            "provider": "github-copilot-sdk", "sdk": SDK_VERSION, "runtime": RUNTIME_VERSION,
            "runtimeFingerprint": runtime_fingerprint(self.runtime), "model": model,
        }

    async def assess(self, bundle: dict[str, Any], prompt: str, run: int) -> dict[str, Any]:
        from copilot import CopilotClient, RuntimeConnection
        from copilot.session_events import AssistantUsageData

        logger = logging.getLogger("copilot")
        logger.handlers = [logging.NullHandler()]
        logger.propagate = False
        with tempfile.TemporaryDirectory(prefix="devpilot-signoff-") as temporary:
            directory = Path(temporary)
            client = CopilotClient(
                connection=RuntimeConnection.for_stdio(path=str(self.runtime)),
                mode="empty", working_directory=str(directory), base_directory=str(directory / "state"),
                env=isolated_environment(directory), github_token=self.token, use_logged_in_user=False,
                builtin_plugin_directories=[], enable_remote_sessions=False, log_level="error",
            )
            session = None
            usage: list[dict[str, Any]] = []
            violation = []
            phase = "capability"
            try:
                await client.start()
                status = await client.get_status()
                if status.version != RUNTIME_VERSION:
                    raise CapabilityError("LIVE_NO_GO_RUNTIME_VERSION_MISMATCH")
                if not (await client.get_auth_status()).isAuthenticated:
                    raise CapabilityError("LIVE_NO_GO_AUTHENTICATION")
                models = await client.list_models()
                if not any(model.id == self.model for model in models):
                    raise CapabilityError("LIVE_NO_GO_EXPLICIT_MODEL_UNAVAILABLE")
                session = await client.create_session(**session_options(self.model, directory, self.credits))
                await verify_session(session, self.model)

                def on_event(event: Any) -> None:
                    event_type = event.type.value
                    if event_type.startswith("tool.execution") or event_type == "session.error":
                        violation.append(event_type)
                    if isinstance(event.data, AssistantUsageData):
                        usage.append({
                            "model": event.data.model, "inputTokens": event.data.input_tokens,
                            "outputTokens": event.data.output_tokens,
                            "cacheReadTokens": event.data.cache_read_tokens,
                            "cacheWriteTokens": event.data.cache_write_tokens,
                            "billing": None,
                        })

                session.on(on_event)
                phase = "assessment"
                event = await session.send_and_wait(prompt, timeout=600)
                await verify_session(session, self.model)
                if violation:
                    raise AssessmentFailure("LIVE_TOOL_OR_SESSION_ERROR")
                if any(item["model"] != self.model for item in usage):
                    raise AssessmentFailure("LIVE_USAGE_MODEL_MISMATCH")
                if event is None or not isinstance(getattr(event.data, "content", None), str):
                    raise AssessmentFailure("LIVE_MISSING_STRUCTURED_RESPONSE")
                return {"text": event.data.content, "usage": usage or None, "model": self.model}
            except (CapabilityError, AssessmentFailure, asyncio.CancelledError):
                raise
            except Exception as error:
                # SDK/network errors are deliberately bounded and redacted, never a fixture fallback.
                if phase == "capability":
                    raise CapabilityError("LIVE_CAPABILITY_RPC_FAILED_" + type(error).__name__) from error
                raise AssessmentFailure("LIVE_ASSESSMENT_FAILED_" + type(error).__name__) from error
            finally:
                try:
                    async with asyncio.timeout(5):
                        if session is not None:
                            await session.abort()
                        await client.stop()
                except (Exception, asyncio.CancelledError):
                    await client.force_stop()
                    # Fail explicitly even if an assessment had apparently succeeded.
                    raise CapabilityError("LIVE_CLEANUP_FORCED_REQUIRES_CONTAINMENT_CONFIRMATION")
