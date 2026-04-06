from __future__ import annotations

from csv import DictWriter
from dataclasses import replace
from datetime import datetime, timezone
import json
from pathlib import Path

from .api import CanvasAPI, CanvasAPIError, token_from_env
from .config import CanvasConnectConfig
from .csv_tools import build_grade_import_csv, load_gradebook_roster
from .export_parser import ensure_unique_student_names, inspect_exports, load_local_dataset
from .matching import (
    build_match_manifest,
    classify_match,
    load_locked_manifest,
    load_match_manifest,
    rank_candidates,
    summarize_locked_records,
    summarize_match_records,
    write_locked_manifest,
)
from .models import CanvasStudent, LockedMatchRecord, MatchRecord, UploadResult


def make_run_dir(output_root: Path, export_paths: list[Path]) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if not export_paths:
        raise ValueError("At least one export path is required to create a run directory.")
    label = export_paths[0].name if len(export_paths) == 1 else f"combined-{len(export_paths)}-{export_paths[0].name}"
    run_dir = output_root / f"{label}__{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir


def inspect_export_step(export_paths: list[Path], run_dir: Path) -> Path:
    dataset = inspect_exports(export_paths, run_dir)
    print(
        f"Inspected {len(export_paths)} export(s) for '{dataset.title}' "
        f"with {len(dataset.submissions)} submissions."
    )
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
    config: CanvasConnectConfig,
    run_dir: Path,
    assume_yes: bool = False,
) -> Path:
    records = load_match_manifest(manifest_path)
    roster_list = load_roster_json(roster_path)
    roster = {student.user_id: student for student in roster_list}
    locked_records: list[LockedMatchRecord] = []
    selected_claims: dict[int, str] = {}
    current_local_names = {record.local_submission_id: record.local_student_name for record in records}
    ensure_unique_student_names(list(current_local_names.values()), context="match review initialization")

    for record in records:
        if record.status == "auto" and not assume_yes:
            locked = _lock_from_record(record, record.matched_user_id, roster, "auto accepted")
            locked_records.append(locked)
            if locked.final_status == "matched" and locked.final_user_id is not None:
                selected_claims[locked.final_user_id] = locked.local_student_name
            continue

        if record.status == "auto" and assume_yes:
            locked = _lock_from_record(record, record.matched_user_id, roster, "auto accepted")
            locked_records.append(locked)
            if locked.final_status == "matched" and locked.final_user_id is not None:
                selected_claims[locked.final_user_id] = locked.local_student_name
            continue

        if assume_yes:
            if record.status in {"needs_review", "duplicate_candidate"} and record.candidates:
                locked = _lock_from_record(record, record.candidates[0].user_id, roster, "accepted top candidate with --yes")
            else:
                locked = _lock_skipped(record, "skipped with --yes")
            locked_records.append(locked)
            if locked.final_status == "matched" and locked.final_user_id is not None:
                selected_claims[locked.final_user_id] = locked.local_student_name
            continue

        locked = _prompt_for_record(record, roster_list, roster, selected_claims, current_local_names, config)
        locked_records.append(locked)
        current_local_names[locked.local_submission_id] = locked.local_student_name
        if locked.final_status == "matched" and locked.final_user_id is not None:
            selected_claims[locked.final_user_id] = locked.local_student_name

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


def post_grades_step(
    locked_manifest_path: Path,
    config: CanvasConnectConfig,
    run_dir: Path,
    use_bulk_endpoint: bool = True,
    test_student_only: bool = False,
    test_source_submission_id: str | None = None,
) -> Path:
    if not (config.canvas_base_url and config.course_id and config.assignment_id):
        raise ValueError("Canvas API grading requires canvas_base_url, course_id, and assignment_id in config.")

    token = token_from_env(config.token_env_var)
    client = CanvasAPI(config.canvas_base_url, token, config.request_timeout_seconds)
    assignment = client.get_assignment(config.course_id, config.assignment_id)
    validate_assignment_for_grading(assignment)

    if config.enforce_manual_post_policy:
        client.update_assignment(
            config.course_id,
            config.assignment_id,
            {"assignment[post_manually]": "true"},
        )

    locked_records = load_locked_manifest(locked_manifest_path)
    matched = [
        record
        for record in locked_records
        if record.final_status == "matched" and record.final_user_id is not None
    ]
    execution_records, test_mode_message = build_execution_records(
        matched,
        config,
        run_dir,
        test_student_only=test_student_only,
        test_source_submission_id=test_source_submission_id,
    )
    if test_mode_message:
        print(test_mode_message)

    grades_dir = run_dir / "grades_api"
    grades_dir.mkdir(parents=True, exist_ok=True)

    if use_bulk_endpoint:
        grade_map = {int(record.final_user_id): format_points(record.total_score) for record in execution_records}
        progress_payload = client.update_assignment_grades(
            config.course_id,
            config.assignment_id,
            grade_map,
        )
        final_progress = progress_payload
        if progress_payload.get("id") is not None:
            final_progress = client.wait_for_progress(int(progress_payload["id"]))
        output = {
            "mode": "bulk",
            "initial_progress": progress_payload,
            "final_progress": final_progress,
            "record_count": len(execution_records),
        }
        json_path = grades_dir / "grade_post_results.json"
        _write_json(json_path, output)
        print(
            f"Posted {len(execution_records)} grades through Canvas API "
            f"(progress state: {final_progress.get('workflow_state', 'unknown')})."
        )
        return json_path

    results: list[dict[str, str | int]] = []
    for record in execution_records:
        try:
            payload = client.grade_submission(
                config.course_id,
                config.assignment_id,
                int(record.final_user_id),
                format_points(record.total_score),
            )
            results.append(
                {
                    "local_submission_id": record.local_submission_id,
                    "user_id": int(record.final_user_id),
                    "student_name": record.final_student_name or "",
                    "status": "graded",
                    "score": format_points(record.total_score),
                    "returned_score": payload.get("score", ""),
                }
            )
        except CanvasAPIError as error:
            results.append(
                {
                    "local_submission_id": record.local_submission_id,
                    "user_id": int(record.final_user_id),
                    "student_name": record.final_student_name or "",
                    "status": "failed",
                    "score": format_points(record.total_score),
                    "message": str(error),
                }
            )

    json_path = grades_dir / "grade_post_results.json"
    _write_json(json_path, results)
    print(
        "Grade API results: "
        + ", ".join(f"{key}={value}" for key, value in summarize_status_rows(results).items())
    )
    return json_path


def upload_submissions_step(
    locked_manifest_path: Path,
    config: CanvasConnectConfig,
    run_dir: Path,
    assume_yes: bool = False,
    test_student_only: bool = False,
    test_source_submission_id: str | None = None,
) -> Path:
    if not (config.canvas_base_url and config.course_id and config.assignment_id):
        raise ValueError("Canvas API upload requires canvas_base_url, course_id, and assignment_id in config.")

    token = token_from_env(config.token_env_var)
    client = CanvasAPI(config.canvas_base_url, token, config.request_timeout_seconds)
    assignment = client.get_assignment(config.course_id, config.assignment_id)
    validate_assignment_for_comment_workflow(assignment, config)

    locked_records = load_locked_manifest(locked_manifest_path)
    local_dataset = load_local_dataset(run_dir / "inspect" / "local_dataset.json")
    submissions_by_id = {submission.submission_id: submission for submission in local_dataset.submissions}
    matched = [record for record in locked_records if record.final_status == "matched" and record.final_user_id is not None]
    execution_records, test_mode_message = build_execution_records(
        matched,
        config,
        run_dir,
        test_student_only=test_student_only,
        test_source_submission_id=test_source_submission_id,
    )
    skipped = [record for record in locked_records if record.final_status != "matched"]
    print(
        f"Prepared comment-attachment upload for {len(execution_records)} matched submissions; {len(skipped)} records will be skipped."
    )
    if test_mode_message:
        print(test_mode_message)
    if execution_records and not assume_yes:
        print("First targets:")
        for record in execution_records[:5]:
            print(f"  - {record.local_student_name} -> {record.final_student_name} ({record.final_user_id})")
        if not confirm("Continue with live Canvas uploads? [y/N]: "):
            raise RuntimeError("Upload cancelled by user.")

    upload_dir = run_dir / "uploads"
    upload_dir.mkdir(parents=True, exist_ok=True)

    results: list[UploadResult] = []
    total_attempts = len(execution_records)
    processed = 0
    if not any(
        [
            config.upload_attach_pdf_as_comment,
            config.upload_post_grade,
            config.upload_comment_enabled,
        ]
    ):
        raise ValueError(
            "Upload configuration would send nothing. Enable at least one of "
            "upload_attach_pdf_as_comment, upload_post_grade, or upload_comment_enabled."
        )
    for record in execution_records:
        processed += 1

        file_id: int | None = None
        try:
            local_submission = submissions_by_id.get(record.local_submission_id)
            if local_submission is None:
                raise ValueError(f"Missing local submission data for {record.local_submission_id}.")

            if config.upload_attach_pdf_as_comment:
                file_payload = client.upload_submission_comment_file(
                    config.course_id,
                    config.assignment_id,
                    record.final_user_id,
                    Path(record.pdf_path),
                )
                file_id = int(file_payload["id"])

            comment_text = build_comment_text(local_submission, config)
            submission_payload = client.grade_or_comment_submission(
                config.course_id,
                config.assignment_id,
                record.final_user_id,
                posted_grade=format_points(record.total_score) if config.upload_post_grade else None,
                comment_text=comment_text,
                comment_file_ids=[file_id] if file_id is not None else None,
            )
            results.append(
                UploadResult(
                    local_submission_id=record.local_submission_id,
                    local_student_name=record.local_student_name,
                    final_user_id=record.final_user_id,
                    final_student_name=record.final_student_name,
                    status="uploaded",
                    step="comment_and_grade",
                    file_id=file_id,
                    submission_id=int(submission_payload.get("id", 0)) if submission_payload.get("id") else None,
                    message=_upload_success_message(config),
                )
            )
        except CanvasAPIError as error:
            error_text = str(error)
            error_step = "comment_and_grade" if "/submissions/" in error_text else "comment_file_upload"
            results.append(
                UploadResult(
                    local_submission_id=record.local_submission_id,
                    local_student_name=record.local_student_name,
                    final_user_id=record.final_user_id,
                    final_student_name=record.final_student_name,
                    status="failed",
                    step=error_step,
                    file_id=file_id,
                    message=error_text,
                )
            )
            print(
                f"[{processed}/{total_attempts}] failed at {error_step}: "
                f"{record.local_student_name} -> {record.final_student_name} ({record.final_user_id})"
            )
        except ValueError as error:
            results.append(
                UploadResult(
                    local_submission_id=record.local_submission_id,
                    local_student_name=record.local_student_name,
                    final_user_id=record.final_user_id,
                    final_student_name=record.final_student_name,
                    status="failed",
                    step="precheck",
                    file_id=file_id,
                    message=str(error),
                )
            )
            print(
                f"[{processed}/{total_attempts}] failed at precheck: "
                f"{record.local_student_name} -> {record.final_student_name} ({record.final_user_id})"
            )

    if config.enforce_manual_post_policy:
        client.update_assignment(
            config.course_id,
            config.assignment_id,
            {"assignment[post_manually]": "true"},
        )

    json_path = upload_dir / "upload_results.json"
    csv_path = upload_dir / "upload_results.csv"
    _write_json(json_path, [result.to_dict() for result in results])
    _write_upload_csv(csv_path, results)
    print("Upload finished: " + ", ".join(f"{key}={value}" for key, value in summarize_uploads(results).items()))
    print(f"Detailed upload logs: {json_path}")
    failure_summary = summarize_failure_messages(results)
    if failure_summary:
        print("Failure summary:")
        for message, count in failure_summary[:3]:
            print(f"  - {count}x {message}")
    return json_path


def run_pipeline(
    export_paths: list[Path],
    config: CanvasConnectConfig,
    gradebook_csv: Path | None = None,
    assignment_column: str | None = None,
    grade_via_api: bool = False,
    test_student_only: bool = False,
    test_source_submission_id: str | None = None,
    upload_submissions: bool = True,
    assume_yes: bool = False,
) -> dict[str, str]:
    output_root = Path(config.output_root)
    run_dir = make_run_dir(output_root, export_paths)
    artifacts: dict[str, str] = {"run_dir": str(run_dir)}

    local_dataset_path = inspect_export_step(export_paths, run_dir)
    artifacts["local_dataset"] = str(local_dataset_path)

    roster_path = load_roster_step(config, run_dir, gradebook_csv)
    artifacts["roster"] = str(roster_path)

    manifest_path = match_step(local_dataset_path, roster_path, config, run_dir)
    artifacts["match_manifest"] = str(manifest_path)

    if not assume_yes and not confirm("Continue to interactive match review? [Y/n]: ", default_yes=True):
        raise RuntimeError("Cancelled before match review.")

    locked_manifest_path = review_matches_step(manifest_path, roster_path, config, run_dir, assume_yes=assume_yes)
    artifacts["locked_manifest"] = str(locked_manifest_path)

    if gradebook_csv is not None:
        chosen_assignment_column = assignment_column or config.assignment_column
        if not chosen_assignment_column:
            raise ValueError("An assignment column must be provided via --assignment-column or config.assignment_column.")
        if not assume_yes and not confirm("Generate Canvas Gradebook import CSV now? [Y/n]: ", default_yes=True):
            raise RuntimeError("Cancelled before grade CSV generation.")
        grade_csv_path = build_grade_csv_step(locked_manifest_path, gradebook_csv, chosen_assignment_column, run_dir)
        artifacts["grade_csv"] = str(grade_csv_path)
    elif grade_via_api:
        if not assume_yes and not confirm("Post grades directly to Canvas through the API now? [Y/n]: ", default_yes=True):
            raise RuntimeError("Cancelled before API grade posting.")
        grade_results_path = post_grades_step(
            locked_manifest_path,
            config,
            run_dir,
            test_student_only=test_student_only,
            test_source_submission_id=test_source_submission_id,
        )
        artifacts["grade_api_results"] = str(grade_results_path)

    if upload_submissions:
        upload_path = upload_submissions_step(
            locked_manifest_path,
            config,
            run_dir,
            assume_yes=assume_yes,
            test_student_only=test_student_only,
            test_source_submission_id=test_source_submission_id,
        )
        artifacts["upload_results"] = str(upload_path)

    _write_json(run_dir / "report.json", artifacts)
    return artifacts


def load_roster_json(path: Path) -> list[CanvasStudent]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return [CanvasStudent.from_dict(row) for row in payload]


def build_execution_records(
    matched_records: list[LockedMatchRecord],
    config: CanvasConnectConfig,
    run_dir: Path,
    test_student_only: bool,
    test_source_submission_id: str | None,
) -> tuple[list[LockedMatchRecord], str]:
    if not test_student_only:
        return matched_records, ""

    if config.test_student_id is None:
        raise ValueError("Test-student mode requires test_student_id in config.toml.")
    if not matched_records:
        raise ValueError("No matched records are available to use as a test-student source.")

    source_submission_id = (test_source_submission_id or config.test_source_local_submission_id or "").strip()
    source_record = select_test_source_record(matched_records, source_submission_id)
    test_student_name = resolve_test_student_name(run_dir, config.test_student_id)
    replay_record = LockedMatchRecord(
        local_submission_id=source_record.local_submission_id,
        local_student_name=source_record.local_student_name,
        total_score=source_record.total_score,
        max_score=source_record.max_score,
        pdf_path=source_record.pdf_path,
        first_scan_path=source_record.first_scan_path,
        final_status="matched",
        final_user_id=int(config.test_student_id),
        final_student_name=test_student_name,
        final_sis_user_id="",
        final_login_id="",
        final_section="",
        source_status=source_record.source_status,
        source_reason=source_record.source_reason,
        reviewer_note=source_record.reviewer_note,
    )
    message = (
        "Test-student mode enabled: replaying "
        f"{source_record.local_student_name} ({source_record.local_submission_id}) "
        f"to {test_student_name} ({config.test_student_id})."
    )
    return [replay_record], message


def select_test_source_record(
    matched_records: list[LockedMatchRecord],
    source_submission_id: str,
) -> LockedMatchRecord:
    if source_submission_id:
        for record in matched_records:
            if record.local_submission_id == source_submission_id:
                return record
        raise ValueError(
            f"Configured test source submission id '{source_submission_id}' was not found in the locked manifest."
        )
    return matched_records[0]


def resolve_test_student_name(run_dir: Path, test_student_id: int) -> str:
    roster_path = run_dir / "roster" / "roster.json"
    if roster_path.exists():
        for student in load_roster_json(roster_path):
            if student.user_id == int(test_student_id):
                return student.name
    return f"Test Student {test_student_id}"


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

def validate_assignment_for_grading(assignment: dict) -> None:
    if assignment.get("id") is None:
        raise ValueError("Canvas assignment lookup did not return an assignment id.")


def validate_assignment_for_comment_workflow(assignment: dict, config: CanvasConnectConfig) -> None:
    validate_assignment_for_grading(assignment)


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


def summarize_status_rows(rows: list[dict[str, str | int]]) -> dict[str, int]:
    summary: dict[str, int] = {}
    for row in rows:
        status = str(row.get("status", "unknown"))
        summary[status] = summary.get(status, 0) + 1
    return summary


def format_points(value: float) -> str:
    numeric = float(value)
    return str(int(numeric)) if numeric.is_integer() else f"{numeric:.2f}".rstrip("0").rstrip(".")


def build_comment_text(local_submission, config: CanvasConnectConfig) -> str | None:
    if not config.upload_comment_enabled:
        return None

    lines: list[str] = []
    grades = sorted(
        local_submission.grades,
        key=lambda grade: _question_sort_key(str(grade.get("displayLabel", ""))),
    )

    if config.upload_comment_include_total_score:
        lines.append(
            f"Total Score: {format_points(local_submission.total_score)}/{format_points(local_submission.max_score)}"
        )

    if config.upload_comment_include_question_scores:
        if lines:
            lines.append("")
        lines.append("Question Scores:")
        for grade in grades:
            label = str(grade.get("displayLabel", "")).strip() or str(grade.get("questionID", "")).strip() or "Question"
            awarded = format_points(float(grade.get("awardedPoints", 0)))
            maximum = format_points(float(grade.get("maxPoints", 0)))
            lines.append(f"- {label}: {awarded}/{maximum}")

    if config.upload_comment_include_individual_notes:
        individual_notes = []
        for grade in grades:
            feedback = str(grade.get("feedback", "")).strip()
            if not feedback:
                continue
            label = str(grade.get("displayLabel", "")).strip() or str(grade.get("questionID", "")).strip() or "Question"
            individual_notes.append(f"- {label}: {feedback}")
        if individual_notes:
            if lines:
                lines.append("")
            lines.append("Individual Notes:")
            lines.extend(individual_notes)

    notes = (local_submission.overall_notes or "").strip()
    if config.upload_comment_include_overall_notes and notes:
        if lines:
            lines.append("")
        lines.extend(["Notes:", notes])

    text = "\n".join(lines).strip()
    return text or None


def _question_sort_key(label: str) -> tuple[int, str]:
    digits = "".join(character for character in label if character.isdigit())
    if digits:
        return int(digits), label
    return 10**9, label.casefold()


def _upload_success_message(config: CanvasConnectConfig) -> str:
    parts: list[str] = []
    if config.upload_attach_pdf_as_comment:
        parts.append("attached PDF as comment")
    if config.upload_comment_enabled:
        parts.append("posted comment text")
    if config.upload_post_grade:
        parts.append("updated grade")
    return ", ".join(parts).capitalize() + "."


def _prompt_for_record(
    record: MatchRecord,
    roster_list: list[CanvasStudent],
    roster_by_id: dict[int, CanvasStudent],
    selected_claims: dict[int, str],
    current_local_names: dict[str, str],
    config: CanvasConnectConfig,
) -> LockedMatchRecord:
    working_record = record
    max_display_candidates = 5

    while True:
        ranked = rank_candidates(working_record.local_student_name, roster_list)
        top_candidate = ranked[0] if ranked else None
        runner_up_score = ranked[1].score if len(ranked) > 1 else None

        status = working_record.status
        reason = working_record.reason
        matched_user_id = working_record.matched_user_id
        matched_student_name = working_record.matched_student_name
        match_score = working_record.match_score

        if top_candidate is not None:
            status, reason = classify_match(
                local_name=working_record.local_student_name,
                top_candidate=top_candidate,
                runner_up_score=runner_up_score,
                requires_review=working_record.name_needs_review,
                config=config,
            )
            matched_user_id = top_candidate.user_id
            matched_student_name = top_candidate.name
            match_score = top_candidate.score

        working_record = replace(
            working_record,
            status=status,
            reason=reason,
            matched_user_id=matched_user_id,
            matched_student_name=matched_student_name,
            match_score=match_score,
            runner_up_score=runner_up_score,
            candidates=ranked[:3],
        )

        claimed_name = (
            selected_claims.get(working_record.matched_user_id)
            if working_record.matched_user_id is not None
            else None
        )
        if (
            working_record.local_student_name != record.local_student_name
            and working_record.status == "auto"
            and claimed_name is None
            and working_record.matched_user_id is not None
        ):
            print()
            print(
                f"Updated name '{working_record.local_student_name}' auto-matched to "
                f"{working_record.matched_student_name} (user_id={working_record.matched_user_id}, score={working_record.match_score})."
            )
            return _lock_from_record(working_record, working_record.matched_user_id, roster_by_id, "")

        print()
        print(f"Resolve: {working_record.local_student_name} [{working_record.status}, {working_record.reason}]")
        print(f"  score: {working_record.total_score}/{working_record.max_score}")
        if working_record.first_scan_path:
            print(f"  first scan: {working_record.first_scan_path}")
        if working_record.name_needs_review:
            print("  note: local export flagged the handwritten name for review.")
        displayed_candidates = ranked[:max_display_candidates]
        for index, candidate in enumerate(displayed_candidates, start=1):
            marker = ""
            claim = selected_claims.get(candidate.user_id)
            if claim is not None:
                marker = f" [already selected for {claim}]"
            elif working_record.matched_user_id == candidate.user_id:
                marker = " [best match]"
            print(
                f"  {index}. {candidate.name} "
                f"(user_id={candidate.user_id}, score={candidate.score}, reason={candidate.reason}){marker}"
            )
        if len(ranked) > max_display_candidates:
            print(f"  ... showing top {max_display_candidates} of {len(ranked)} candidates")
        print("  r. rename local student name and rematch")
        print("  s. mark uncertain / skip this record")
        print("  u. enter a Canvas user id manually")

        choice = input("Choose candidate number, or r/s/u [default 1]: ").strip().casefold()
        if not choice and displayed_candidates:
            choice = "1"
        if choice.isdigit():
            index = int(choice) - 1
            if index < 0 or index >= len(ranked):
                print("Candidate does not exist.")
                continue
            candidate = ranked[index]
            if candidate.user_id in selected_claims:
                claim = selected_claims[candidate.user_id]
                if not confirm(f"{candidate.name} is already selected for {claim}. Use anyway? [y/N]: "):
                    continue
            selected_record = replace(
                working_record,
                matched_user_id=candidate.user_id,
                matched_student_name=candidate.name,
                match_score=candidate.score,
            )
            return _lock_from_record(selected_record, candidate.user_id, roster_by_id, "")
        if choice == "r":
            updated_name = input("Updated student name: ").strip()
            if not updated_name:
                print("Name cannot be empty.")
                continue
            _validate_renamed_student_name(record.local_submission_id, updated_name, current_local_names)
            current_local_names[record.local_submission_id] = updated_name
            working_record = replace(working_record, local_student_name=updated_name)
            continue
        if choice == "s":
            note = input("Uncertain note (optional): ").strip()
            return _lock_skipped(working_record, note)
        if choice == "u":
            user_id_raw = input("Canvas user id: ").strip()
            if not user_id_raw.isdigit():
                print("Enter a numeric Canvas user id.")
                continue
            user_id = int(user_id_raw)
            if user_id not in roster_by_id:
                print("That user id is not in the loaded roster.")
                continue
            if user_id in selected_claims:
                claim = selected_claims[user_id]
                if not confirm(f"{roster_by_id[user_id].name} is already selected for {claim}. Use anyway? [y/N]: "):
                    continue
            return _lock_from_record(working_record, user_id, roster_by_id, "")
        print("Invalid choice.")


def _lock_from_record(
    record: MatchRecord,
    user_id: int | None,
    roster_by_id: dict[int, CanvasStudent],
    reviewer_note: str,
) -> LockedMatchRecord:
    student = roster_by_id.get(user_id) if user_id is not None else None
    if student is None:
        return _lock_skipped(record, reviewer_note or "No matching Canvas user selected.")
    return LockedMatchRecord(
        local_submission_id=record.local_submission_id,
        local_student_name=record.local_student_name,
        total_score=record.total_score,
        max_score=record.max_score,
        pdf_path=record.pdf_path,
        first_scan_path=record.first_scan_path,
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
        first_scan_path=record.first_scan_path,
        final_status="skipped",
        final_user_id=None,
        final_student_name=None,
        source_status=record.status,
        source_reason=record.reason,
        reviewer_note=reviewer_note,
    )


def _validate_renamed_student_name(
    current_submission_id: str,
    updated_name: str,
    current_local_names: dict[str, str],
) -> None:
    candidate_names = [
        name
        for submission_id, name in current_local_names.items()
        if submission_id != current_submission_id
    ] + [updated_name]
    ensure_unique_student_names(candidate_names, context="name correction")


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
                "step",
                "file_id",
                "submission_id",
                "message",
            ],
        )
        writer.writeheader()
        for result in results:
            writer.writerow(result.to_dict())


def summarize_failure_messages(results: list[UploadResult]) -> list[tuple[str, int]]:
    grouped: dict[str, int] = {}
    for result in results:
        if result.status != "failed":
            continue
        key = f"{result.step}: {result.message}"
        grouped[key] = grouped.get(key, 0) + 1
    return sorted(grouped.items(), key=lambda item: (-item[1], item[0]))
