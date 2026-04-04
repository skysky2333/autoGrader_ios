from __future__ import annotations

from csv import DictReader, DictWriter
from pathlib import Path

from .models import CanvasStudent, LockedMatchRecord


GRADEBOOK_STUDENT_ID_HEADERS = ["Student ID", "ID"]
GRADEBOOK_SIS_HEADERS = ["SIS User ID"]
GRADEBOOK_LOGIN_HEADERS = ["SIS Login ID", "Login ID"]


def load_gradebook_roster(path: Path) -> list[CanvasStudent]:
    students: list[CanvasStudent] = []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = DictReader(handle)
        for row in reader:
            name = (row.get("Student Name") or "").strip()
            if not name or name == "Points Possible":
                continue
            user_id = _first_value(row, GRADEBOOK_STUDENT_ID_HEADERS)
            students.append(
                CanvasStudent(
                    user_id=int(user_id) if user_id else 0,
                    name=name,
                    sis_user_id=_first_value(row, GRADEBOOK_SIS_HEADERS),
                    login_id=_first_value(row, GRADEBOOK_LOGIN_HEADERS),
                    section=(row.get("Section") or "").strip(),
                )
            )
    return students


def build_grade_import_csv(
    template_path: Path,
    output_path: Path,
    assignment_column: str,
    locked_records: list[LockedMatchRecord],
) -> dict[str, int]:
    with template_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = DictReader(handle)
        fieldnames = reader.fieldnames or []
        if assignment_column not in fieldnames:
            raise ValueError(
                f"Assignment column '{assignment_column}' was not found in the template CSV. "
                f"Available columns: {', '.join(fieldnames)}"
            )
        rows = list(reader)

    matched_by_user_id = {
        str(record.final_user_id): record
        for record in locked_records
        if record.final_status == "matched" and record.final_user_id is not None
    }

    updated = 0
    unmatched_template_rows = 0
    for row in rows:
        if (row.get("Student Name") or "").strip() == "Points Possible":
            continue
        user_id = _first_value(row, GRADEBOOK_STUDENT_ID_HEADERS)
        if not user_id:
            unmatched_template_rows += 1
            continue
        record = matched_by_user_id.get(user_id)
        if record is None:
            continue
        row[assignment_column] = _format_score(record.total_score)
        updated += 1

    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    return {"updated_rows": updated, "template_rows_without_id": unmatched_template_rows}


def _first_value(row: dict[str, str], headers: list[str]) -> str:
    for header in headers:
        value = (row.get(header) or "").strip()
        if value:
            return value
    return ""


def _format_score(value: float) -> str:
    numeric = float(value)
    return str(int(numeric)) if numeric.is_integer() else f"{numeric:.2f}".rstrip("0").rstrip(".")
