from __future__ import annotations

from csv import DictWriter
from datetime import datetime, timezone
import json
import os
from pathlib import Path

from .api import CanvasAPI, CanvasAPIError, token_from_env
from .config import CanvasConnectConfig
from .csv_tools import build_grade_import_csv, load_gradebook_roster
from .export_parser import inspect_export, load_local_dataset
from .matching import (
    build_match_manifest,
    load_locked_manifest,
    load_match_manifest,
    summarize_locked_records,
    summarize_match_records,
    write_locked_manifest,
)
from .models import CanvasStudent, LockedMatchRecord, MatchRecord, UploadResult


def make_run_dir(output_root: Path, export_path: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = output_root / f"{export_path.name}__{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir


def inspect_export_step(export_path: Path, run_dir: Path) -> Path:
    dataset = inspect_export(export_path, run_dir)
    print(f"Inspected export '{dataset.title}' with {len(dataset.submissions)} submissions.")
    return run_dir / "inspect" / "local_dataset.json"


def load_roster_step(
    config: CanvasConnectConfig,
    run_dir: Path,
    gradebook_csv: Path | None = None,
) -> Path:
    roster_dir = run_dir / "roster"
    roster_dir.mkdir(parents=True, exist_ok=True)

    api_students: list[CanvasStudent] = []
    if config.canvas_base_url and config.course_id:
        token = token_from_env(config.token_env_var)
        client = CanvasAPI(config.canvas_base_url, token, config.request_timeout_seconds)
        api_students = client.list_course_students(config.course_id)

    csv_students: list[CanvasStudent] = []
    if gradebook_csv is not None:
        csv_students = load_gradebook_roster(gradebook_csv)

    roster = merge_rosters(api_students, csv_students)
    if not roster:
        raise ValueError("No roster data was loaded. Provide Canvas API config or a Gradebook CSV.")

    json_path = roster_dir / "roster.json"
    csv_path = roster_dir / "roster.csv"
    _write_json(json_path, [student.to_dict() for student in roster])
    _write_roster_csv(csv_path, roster)
    print(f"Loaded roster with {len(roster)} students.")
    return json_path


def match_step(local_dataset_path: Path, roster_path: Path, config: CanvasConnectConfig, run_dir: Path) -> Path:
    dataset = load_local_dataset(local_dataset_path)
    roster = load_roster_json(roster_path)
    records = build_match_manifest(dataset, roster, config, run_dir)
    summary = summarize_match_records(records)
    print(
        "Match summary: "
        + ", ".join(f"{key}={value}" for key, value in summary.items() if value)
    )
    return run_dir / "match" / "match_manifest.json"


def review_matches_step(
    manifest_path: Path,
    roster_path: Path,
    run_dir: Path,
    assume_yes: bool = False,
) -> Path:
    records = load_match_manifest(manifest_path)
    roster = {student.user_id: student for student in load_roster_json(roster_path)}
    locked_records: list[LockedMatchRecord] = []

    for record in records:
        if record.status == "auto" and not assume_yes:
            locked_records.append(_lock_from_record(record, record.matched_user_id, roster, "auto accepted"))
            continue

        if record.status == "auto" and assume_yes:
            locked_records.append(_lock_from_record(record, record.matched_user_id, roster, "auto accepted"))
            continue

        if assume_yes:
            if record.status in {"needs_review", "duplicate_candidate"} and record.candidates:
                locked_records.append(_lock_from_record(record, record.candidates[0].user_id, roster, "accepted top candidate with --yes"))
            else:
                locked_records.append(_lock_skipped(record, "skipped with --yes"))
            continue

        locked_records.append(_prompt_for_record(record, roster))

    locked_dir = run_dir / "match"
    locked_dir.mkdir(parents=True, exist_ok=True)
    json_path = locked_dir / "locked_manifest.json"
    csv_path = locked_dir / "locked_manifest.csv"
    write_locked_manifest(locked_records, json_path, csv_path)
    summary = summarize_locked_records(locked_records)
    print(
        "Locked match summary: "
        + ", ".join(f"{key}={value}" for key, value in summary.items() if value)
    )
    return json_path


def build_grade_csv_step(
    locked_manifest_path: Path,
    gradebook_csv_path: Path,
    assignment_column: str,
    run_dir: Path,
) -> Path:
    locked_records = load_locked_manifest(locked_manifest_path)
    gradebook_dir = run_dir / "gradebook"
    gradebook_dir.mkdir(parents=True, exist_ok=True)
    output_path = gradebook_dir / "grade_import.csv"
    stats = build_grade_import_csv(gradebook_csv_path, output_path, assignment_column, locked_records)
    print(f"Generated Gradebook CSV with {stats['updated_rows']} updated student rows.")
    return output_path


def upload_submissions_step(
    locked_manifest_path: Path,
    config: CanvasConnectConfig,
    run_dir: Path,
    assume_yes: bool = False,
) -> Path:
    if not (config.canvas_base_url and config.course_id and config.assignment_id):
        raise ValueError("Canvas API upload requires canvas_base_url, course_id, and assignment_id in config.")

    token = token_from_env(config.token_env_var)
    client = CanvasAPI(config.canvas_base_url, token, config.request_timeout_seconds)
    assignment = client.get_assignment(config.course_id, config.assignment_id)
    validate_assignment_for_upload(assignment, config)

    locked_records = load_locked_manifest(locked_manifest_path)
    matched = [record for record in locked_records if record.final_status == "matched" and record.final_user_id is not None]
    skipped = [record for record in locked_records if record.final_status != "matched"]
    print(
        f"Prepared upload for {len(matched)} matched submissions; {len(skipped)} records will be skipped."
    )
    if matched and not assume_yes:
        print("First targets:")
        for record in matched[:5]:
            print(f"  - {record.local_student_name} -> {record.final_student_name} ({record.final_user_id})")
        if not confirm("Continue with live Canvas uploads? [y/N]: "):
            raise RuntimeError("Upload cancelled by user.")

    upload_dir = run_dir / "uploads"
    upload_dir.mkdir(parents=True, exist_ok=True)

    results: list[UploadResult] = []
    for record in locked_records:
        if record.final_status != "matched" or record.final_user_id is None:
            results.append(
                UploadResult(
                    local_submission_id=record.local_submission_id,
                    local_student_name=record.local_student_name,
                    final_user_id=record.final_user_id,
                    final_student_name=record.final_student_name,
                    status="skipped",
                    message="Record was not locked to a Canvas student.",
                )
            )
            continue

        try:
            file_payload = client.upload_submission_file(
                config.course_id,
                config.assignment_id,
                record.final_user_id,
                Path(record.pdf_path),
            )
            submission_payload = client.submit_file_on_behalf(
                config.course_id,
                config.assignment_id,
                record.final_user_id,
                int(file_payload["id"]),
            )
            results.append(
                UploadResult(
                    local_submission_id=record.local_submission_id,
                    local_student_name=record.local_student_name,
                    final_user_id=record.final_user_id,
                    final_student_name=record.final_student_name,
                    status="uploaded",
                    file_id=int(file_payload["id"]),
                    submission_id=int(submission_payload.get("id", 0)) if submission_payload.get("id") else None,
                    message="Uploaded and submitted.",
                )
            )
        except CanvasAPIError as error:
            results.append(
                UploadResult(
                    local_submission_id=record.local_submission_id,
                    local_student_name=record.local_student_name,
                    final_user_id=record.final_user_id,
                    final_student_name=record.final_student_name,
                    status="failed",
                    message=str(error),
                )
            )

    if config.enforce_manual_post_policy or config.lock_assignment_after_upload:
        fields: dict[str, str] = {}
        if config.enforce_manual_post_policy:
            fields["assignment[post_manually]"] = "true"
        if config.lock_assignment_after_upload:
            fields["assignment[lock_at]"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        if fields:
            client.update_assignment(config.course_id, config.assignment_id, fields)

    json_path = upload_dir / "upload_results.json"
    csv_path = upload_dir / "upload_results.csv"
    _write_json(json_path, [result.to_dict() for result in results])
    _write_upload_csv(csv_path, results)
    print("Upload finished: " + ", ".join(f"{key}={value}" for key, value in summarize_uploads(results).items()))
    return json_path


def run_pipeline(
    export_path: Path,
    config: CanvasConnectConfig,
    gradebook_csv: Path | None = None,
    assignment_column: str | None = None,
    upload_submissions: bool = True,
    assume_yes: bool = False,
) -> dict[str, str]:
    output_root = Path(config.output_root)
    run_dir = make_run_dir(output_root, export_path)
    artifacts: dict[str, str] = {"run_dir": str(run_dir)}

    local_dataset_path = inspect_export_step(export_path, run_dir)
    artifacts["local_dataset"] = str(local_dataset_path)

    roster_path = load_roster_step(config, run_dir, gradebook_csv)
    artifacts["roster"] = str(roster_path)

    manifest_path = match_step(local_dataset_path, roster_path, config, run_dir)
    artifacts["match_manifest"] = str(manifest_path)

    if not assume_yes and not confirm("Continue to interactive match review? [Y/n]: ", default_yes=True):
        raise RuntimeError("Cancelled before match review.")

    locked_manifest_path = review_matches_step(manifest_path, roster_path, run_dir, assume_yes=assume_yes)
    artifacts["locked_manifest"] = str(locked_manifest_path)

    if gradebook_csv is not None:
        chosen_assignment_column = assignment_column or config.assignment_column
        if not chosen_assignment_column:
            raise ValueError("An assignment column must be provided via --assignment-column or config.assignment_column.")
        if not assume_yes and not confirm("Generate Canvas Gradebook import CSV now? [Y/n]: ", default_yes=True):
            raise RuntimeError("Cancelled before grade CSV generation.")
        grade_csv_path = build_grade_csv_step(locked_manifest_path, gradebook_csv, chosen_assignment_column, run_dir)
        artifacts["grade_csv"] = str(grade_csv_path)

    if upload_submissions:
        upload_path = upload_submissions_step(locked_manifest_path, config, run_dir, assume_yes=assume_yes)
        artifacts["upload_results"] = str(upload_path)

    _write_json(run_dir / "report.json", artifacts)
    return artifacts


def load_roster_json(path: Path) -> list[CanvasStudent]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return [CanvasStudent.from_dict(row) for row in payload]


def merge_rosters(api_students: list[CanvasStudent], csv_students: list[CanvasStudent]) -> list[CanvasStudent]:
    if not api_students:
        return csv_students

    merged = {student.user_id: student for student in api_students}
    for student in csv_students:
        if student.user_id and student.user_id in merged:
            existing = merged[student.user_id]
            if not existing.section and student.section:
                existing.section = student.section
            if not existing.sis_user_id and student.sis_user_id:
                existing.sis_user_id = student.sis_user_id
            if not existing.login_id and student.login_id:
                existing.login_id = student.login_id
    return sorted(merged.values(), key=lambda student: student.name.casefold())


def validate_assignment_for_upload(assignment: dict, config: CanvasConnectConfig) -> None:
    submission_types = assignment.get("submission_types", []) or []
    if "online_upload" not in submission_types:
        raise ValueError("Canvas assignment does not allow online file uploads.")

    published = bool(assignment.get("published"))
    if config.require_unpublished_assignment and published:
        raise ValueError(
            "Canvas assignment is published. To keep exams hidden and avoid student self-submissions, "
            "create it unpublished before running uploads."
        )


def confirm(prompt: str, default_yes: bool = False) -> bool:
    raw = input(prompt).strip().casefold()
    if not raw:
        return default_yes
    return raw in {"y", "yes"}


def summarize_uploads(results: list[UploadResult]) -> dict[str, int]:
    summary: dict[str, int] = {}
    for result in results:
        summary[result.status] = summary.get(result.status, 0) + 1
    return summary


def _prompt_for_record(record: MatchRecord, roster: dict[int, CanvasStudent]) -> LockedMatchRecord:
    print()
    print(f"Resolve: {record.local_student_name} [{record.status}, {record.reason}]")
    print(f"  score: {record.total_score}/{record.max_score}")
    if record.name_needs_review:
        print("  note: local export flagged the handwritten name for review.")
    if record.candidates:
        for index, candidate in enumerate(record.candidates, start=1):
            print(
                f"  {index}. {candidate.name} (user_id={candidate.user_id}, score={candidate.score}, reason={candidate.reason})"
            )
    print("  s. skip this record")
    print("  u. enter a Canvas user id manually")

    while True:
        choice = input("Choose candidate [1/2/3/s/u]: ").strip().casefold()
        if choice in {"1", "2", "3"}:
            index = int(choice) - 1
            if index >= len(record.candidates):
                print("Candidate does not exist.")
                continue
            note = input("Reviewer note (optional): ").strip()
            return _lock_from_record(record, record.candidates[index].user_id, roster, note)
        if choice == "s":
            note = input("Reviewer note (optional): ").strip()
            return _lock_skipped(record, note)
        if choice == "u":
            user_id_raw = input("Canvas user id: ").strip()
            if not user_id_raw.isdigit():
                print("Enter a numeric Canvas user id.")
                continue
            user_id = int(user_id_raw)
            if user_id not in roster:
                print("That user id is not in the loaded roster.")
                continue
            note = input("Reviewer note (optional): ").strip()
            return _lock_from_record(record, user_id, roster, note)
        print("Invalid choice.")


def _lock_from_record(
    record: MatchRecord,
    user_id: int | None,
    roster: dict[int, CanvasStudent],
    reviewer_note: str,
) -> LockedMatchRecord:
    student = roster.get(user_id) if user_id is not None else None
    if student is None:
        return _lock_skipped(record, reviewer_note or "No matching Canvas user selected.")
    return LockedMatchRecord(
        local_submission_id=record.local_submission_id,
        local_student_name=record.local_student_name,
        total_score=record.total_score,
        max_score=record.max_score,
        pdf_path=record.pdf_path,
        final_status="matched",
        final_user_id=student.user_id,
        final_student_name=student.name,
        final_sis_user_id=student.sis_user_id,
        final_login_id=student.login_id,
        final_section=student.section,
        source_status=record.status,
        source_reason=record.reason,
        reviewer_note=reviewer_note,
    )


def _lock_skipped(record: MatchRecord, reviewer_note: str) -> LockedMatchRecord:
    return LockedMatchRecord(
        local_submission_id=record.local_submission_id,
        local_student_name=record.local_student_name,
        total_score=record.total_score,
        max_score=record.max_score,
        pdf_path=record.pdf_path,
        final_status="skipped",
        final_user_id=None,
        final_student_name=None,
        source_status=record.status,
        source_reason=record.reason,
        reviewer_note=reviewer_note,
    )


def _write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _write_roster_csv(path: Path, roster: list[CanvasStudent]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = DictWriter(
            handle,
            fieldnames=["user_id", "name", "sortable_name", "short_name", "sis_user_id", "login_id", "section"],
        )
        writer.writeheader()
        for student in roster:
            writer.writerow(student.to_dict())


def _write_upload_csv(path: Path, results: list[UploadResult]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = DictWriter(
            handle,
            fieldnames=[
                "local_submission_id",
                "local_student_name",
                "final_user_id",
                "final_student_name",
                "status",
                "file_id",
                "submission_id",
                "message",
            ],
        )
        writer.writeheader()
        for result in results:
            writer.writerow(result.to_dict())
