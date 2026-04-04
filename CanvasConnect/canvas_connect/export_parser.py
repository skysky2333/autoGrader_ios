from __future__ import annotations

from csv import DictReader, DictWriter
import json
from pathlib import Path
import re

from .matching import normalize_name
from .models import LocalDataset, LocalSubmission
from .pdf import build_submission_pdf


def inspect_exports(export_paths: list[Path], run_dir: Path) -> LocalDataset:
    if not export_paths:
        raise ValueError("At least one export path is required.")

    inspect_dir = run_dir / "inspect"
    pdf_dir = inspect_dir / "pdfs"
    inspect_dir.mkdir(parents=True, exist_ok=True)
    pdf_dir.mkdir(parents=True, exist_ok=True)

    summaries: list[dict] = []
    submissions: list[LocalSubmission] = []
    for export_path in export_paths:
        if not export_path.exists():
            raise FileNotFoundError(f"Export path does not exist: {export_path}")

        session_summary = _load_json(export_path / "session-summary.json")
        summaries.append(session_summary)

        submissions_root = export_path / "submissions"
        if not submissions_root.exists():
            raise FileNotFoundError(f"Missing submissions directory: {submissions_root}")

        for child_dir in sorted(submissions_root.iterdir(), key=lambda item: item.name.casefold()):
            if not child_dir.is_dir():
                continue
            summary_path = child_dir / "summary.json"
            scans_dir = child_dir / "scans"
            if not summary_path.exists():
                continue

            summary = _load_json(summary_path)
            scan_paths = sorted(
                [path for path in scans_dir.iterdir() if path.is_file() and not path.name.startswith(".")],
                key=_page_sort_key,
            )

            pdf_name = f"{safe_slug(summary['studentName'])}-{summary['id'][:8]}.pdf"
            pdf_path = pdf_dir / pdf_name
            build_submission_pdf(scan_paths, pdf_path)

            submissions.append(
                LocalSubmission(
                    submission_id=summary["id"],
                    folder_name=child_dir.name,
                    student_name=summary["studentName"],
                    total_score=float(summary["totalScore"]),
                    max_score=float(summary["maxScore"]),
                    teacher_reviewed=bool(summary.get("teacherReviewed", False)),
                    name_needs_review=bool(summary.get("nameNeedsReview", False)),
                    created_at=summary.get("createdAt"),
                    overall_notes=summary.get("overallNotes", ""),
                    scan_paths=[str(path) for path in scan_paths],
                    pdf_path=str(pdf_path),
                    grades=list(summary.get("grades", [])),
                )
            )

    ensure_unique_student_names(
        [submission.student_name for submission in submissions],
        context="export import",
    )

    dataset = LocalDataset(
        export_paths=[str(path) for path in export_paths],
        title=_combined_title(export_paths, summaries),
        created_at=_latest_created_at(summaries),
        question_count=max(int(summary.get("questionCount", 0)) for summary in summaries),
        total_points=max(float(summary.get("totalPoints", 0)) for summary in summaries),
        submissions=submissions,
    )

    _write_json(inspect_dir / "local_dataset.json", dataset.to_dict())
    _write_submission_csv(inspect_dir / "local_submissions.csv", submissions)
    _write_session_csv_snapshots(export_paths, inspect_dir)
    return dataset


def inspect_export(export_path: Path, run_dir: Path) -> LocalDataset:
    return inspect_exports([export_path], run_dir)


def load_local_dataset(path: Path) -> LocalDataset:
    return LocalDataset.from_dict(_load_json(path))


def safe_slug(value: str) -> str:
    cleaned = re.sub(r"[^0-9A-Za-z]+", "-", value).strip("-")
    return cleaned or "submission"


def _page_sort_key(path: Path) -> tuple[int, str]:
    match = re.search(r"page-(\d+)", path.name)
    if match:
        return int(match.group(1)), path.name
    return 10**9, path.name.casefold()


def _load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _write_json(path: Path, payload: dict) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _write_submission_csv(path: Path, submissions: list[LocalSubmission]) -> None:
    fieldnames = [
        "submission_id",
        "student_name",
        "total_score",
        "max_score",
        "teacher_reviewed",
        "name_needs_review",
        "created_at",
        "pdf_path",
        "scan_count",
        "folder_name",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for submission in submissions:
            writer.writerow(
                {
                    "submission_id": submission.submission_id,
                    "student_name": submission.student_name,
                    "total_score": _format_score(submission.total_score),
                    "max_score": _format_score(submission.max_score),
                    "teacher_reviewed": "yes" if submission.teacher_reviewed else "no",
                    "name_needs_review": "yes" if submission.name_needs_review else "no",
                    "created_at": submission.created_at or "",
                    "pdf_path": submission.pdf_path,
                    "scan_count": len(submission.scan_paths),
                    "folder_name": submission.folder_name,
                }
            )


def _write_session_csv_snapshots(export_paths: list[Path], inspect_dir: Path) -> None:
    snapshot_dir = inspect_dir / "session_csv_snapshots"
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    for export_path in export_paths:
        source = export_path / "session.csv"
        if not source.exists():
            continue

        target = snapshot_dir / f"{safe_slug(export_path.name)}.csv"
        with source.open("r", encoding="utf-8", newline="") as source_handle, target.open(
            "w",
            encoding="utf-8",
            newline="",
        ) as target_handle:
            reader = DictReader(source_handle)
            writer = DictWriter(target_handle, fieldnames=reader.fieldnames or [])
            writer.writeheader()
            for row in reader:
                writer.writerow(row)


def ensure_unique_student_names(student_names: list[str], context: str) -> None:
    seen: dict[str, str] = {}
    duplicates: dict[str, list[str]] = {}
    for raw_name in student_names:
        normalized = normalize_name(raw_name)
        if not normalized:
            normalized = raw_name.strip().casefold()
        if normalized in seen:
            duplicates.setdefault(normalized, [seen[normalized]]).append(raw_name)
        else:
            seen[normalized] = raw_name

    if duplicates:
        duplicate_text = "; ".join(
            f"{normalized}: {', '.join(names)}"
            for normalized, names in sorted(duplicates.items())
        )
        raise ValueError(f"Duplicate student names detected during {context}: {duplicate_text}")


def _combined_title(export_paths: list[Path], summaries: list[dict]) -> str:
    titles = [summary.get("title", path.name) for path, summary in zip(export_paths, summaries)]
    unique_titles = list(dict.fromkeys(titles))
    if len(unique_titles) == 1:
        return unique_titles[0]
    return f"Combined-{len(export_paths)}-Exports"


def _latest_created_at(summaries: list[dict]) -> str | None:
    created_values = [summary.get("createdAt") for summary in summaries if summary.get("createdAt") is not None]
    if not created_values:
        return None
    return max(created_values)


def _format_score(value: float) -> str:
    numeric = float(value)
    return str(int(numeric)) if numeric.is_integer() else f"{numeric:.2f}".rstrip("0").rstrip(".")
