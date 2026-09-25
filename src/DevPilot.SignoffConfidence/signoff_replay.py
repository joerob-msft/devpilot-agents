"""CLI entry point; evaluation never installs dependencies or downloads a runtime."""

from __future__ import annotations

import argparse
import asyncio
from pathlib import Path
import sys

if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11+ is required; provisioning is separate from evaluation.")
try:
    from contracts import ContractError, canonical, digest, load_json
    from replay import (
        Cancelled, CapabilityError, FixtureProvider, assert_output_root, read_bundles, run_replay,
    )
except ModuleNotFoundError as error:
    print("Missing replay dependency; install requirements.txt in an explicit Python 3.11+ environment before evaluation.",
          file=sys.stderr)
    raise SystemExit(2) from error


def integer(low: int, high: int):
    def parse(value: str) -> int:
        number = int(value)
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"Value must be {low}..{high}")
        return number
    return parse


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Read-only sign-off replay; no approval authorization.")
    commands = root.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-bundle")
    validate.add_argument("--input", type=Path, required=True)
    validate.add_argument("--max-cases", type=integer(1, 25), default=25)
    run = commands.add_parser("run")
    run.add_argument("--input", type=Path, required=True)
    run.add_argument("--mode", choices=("offline", "live"), required=True)
    run.add_argument("--model", required=True)
    run.add_argument("--output-root", type=Path, required=True)
    run.add_argument("--fixtures", type=Path)
    run.add_argument("--runtime-path", type=Path)
    run.add_argument("--max-cases", type=integer(1, 25), default=25)
    run.add_argument("--deadline-seconds", type=integer(1, 600), default=60)
    run.add_argument("--max-attempts", type=integer(1, 2), default=1)
    run.add_argument("--resume", action="store_true")
    run.add_argument("--exploratory", action="store_true")
    run.add_argument("--cancel-file", type=Path)
    run.add_argument("--max-ai-credits", type=float, default=30.0)
    return root


async def main_async(args: argparse.Namespace) -> int:
    bundles = read_bundles(args.input, args.max_cases)
    if args.command == "validate-bundle":
        print(canonical({"valid": True, "cases": len(bundles), "schemaVersion": 1}))
        return 0
    root = assert_output_root(args.output_root)
    if not args.model.strip() or args.model.lower() in ("auto", "default"):
        raise ContractError("EXPLICIT_MODEL_REQUIRED")
    fixtures = None
    if args.mode == "offline":
        if args.fixtures is None or args.runtime_path is not None:
            raise ContractError("OFFLINE_REQUIRES_FIXTURES_AND_NO_RUNTIME")
        fixtures = load_json(args.fixtures)
        provider = FixtureProvider(fixtures, bundles, args.model)
    else:
        if args.fixtures is not None or args.runtime_path is None:
            raise ContractError("LIVE_REQUIRES_RUNTIME_AND_NO_FIXTURES")
        from sdk_adapter import SdkProvider
        provider = SdkProvider(args.runtime_path, args.model, args.max_ai_credits)
    settings = {
        "mode": args.mode, "model": args.model, "maxCases": args.max_cases,
        "deadlineSeconds": args.deadline_seconds, "maxAttempts": args.max_attempts,
        "exploratory": args.exploratory, "concurrency": 1,
        "maxAiCreditsPerAssessment": args.max_ai_credits if args.mode == "live" else None,
        "fixturesFingerprint": digest(fixtures) if fixtures is not None else None,
        "provider": provider.metadata,
    }
    results = await run_replay(bundles, provider, root, settings, args.resume, args.cancel_file)
    print(canonical({"outputRoot": str(root), "cases": len(results), "authorization": "NONE",
                     "recommendations": {key: sum(r["recommendation"] == key for r in results)
                                          for key in ("APPROVE", "REQUEST_CHANGES", "NEEDS_HUMAN_REVIEW")}}))
    return 3 if any(b["code"] == "LIVE_CAPABILITY_NO_GO" for r in results for b in r["blockers"]) else 0


def main() -> int:
    try:
        return asyncio.run(main_async(parser().parse_args()))
    except ContractError as error:
        print(canonical({"error": str(error), "authorization": "NONE"}), file=sys.stderr)
        return 2
    except CapabilityError as error:
        print(canonical({"error": str(error), "authorization": "NONE"}), file=sys.stderr)
        return 3
    except (Cancelled, KeyboardInterrupt):
        print('{"error":"CANCELLED","authorization":"NONE"}', file=sys.stderr)
        return 130
    except OSError as error:
        print(canonical({"error": "FILESYSTEM_ERROR", "type": type(error).__name__, "authorization": "NONE"}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
