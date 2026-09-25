"""Validate separately authorized local report delivery; no network/model access."""
import argparse
from contextlib import closing
from pathlib import Path
import sqlite3
import sys

from contracts import ContractError, canonical, digest, load_json
from observer_contracts import validate
from replay import assert_output_root


def prepare(config_path: Path, report_path: Path) -> dict:
    config = load_json(config_path)
    validate(config, "observer-delivery")
    study = assert_output_root(Path(config["studyRoot"]))
    outbox = assert_output_root(Path(config["stateRoot"]))
    if study == outbox:
        raise ContractError("REPORT_DELIVERY_REQUIRES_SEPARATE_STATE_ROOT")
    value = load_json(report_path)
    report_hash = digest(value)
    expected = study / "reports" / (report_hash + ".json")
    if report_path.resolve() != expected or value.get("studyId") != config["studyId"] or value.get("authorization") != "NONE":
        raise ContractError("DELIVERY_REQUIRES_IMMUTABLE_STUDY_REPORT")
    with closing(sqlite3.connect((study / "observer.sqlite").as_uri() + "?mode=ro", uri=True)) as database:
        row = database.execute("SELECT payload FROM reports WHERE id=?", (report_hash,)).fetchone()
    if row is None or row[0] != canonical(value):
        raise ContractError("REPORT_NOT_COMMITTED_TO_STUDY")
    summary = (f"Sign-off observer {config['studyId']}; as of {value['asOf']}.\n"
               f"Evaluation admissions: {value['admissions']}; eligible human comparisons: {value['livePolicyAgreement']['eligible']}.\n"
               "Advisory only; no approval authorization. Diagnostics are not final policy. "
               "Completion is not readiness ground truth. Lead time is not time saved.\n"
               "Review the private local study report for gaps and cohort denominators.")
    return {"config": config, "eventKey": digest({"study": config["studyId"], "report": report_hash, "chat": config["chatId"]}),
            "reportHash": report_hash, "summary": summary}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(canonical(prepare(args.config, args.report)))
    except (ContractError, sqlite3.Error, OSError) as error:
        print(canonical({"error": str(error) if isinstance(error, ContractError) else type(error).__name__}), file=sys.stderr)
        sys.exit(2)
