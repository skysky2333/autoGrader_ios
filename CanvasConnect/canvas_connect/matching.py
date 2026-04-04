from __future__ import annotations

from csv import DictWriter
from difflib import SequenceMatcher
import json
from pathlib import Path
import re
import unicodedata

from .config import CanvasConnectConfig
from .models import CanvasStudent, LocalDataset, LockedMatchRecord, MatchCandidate, MatchRecord


def build_match_manifest(
    dataset: LocalDataset,
    roster: list[CanvasStudent],
    config: CanvasConnectConfig,
    run_dir: Path,
) -> list[MatchRecord]:
    if not roster:
        raise ValueError("Roster is empty. Load a roster before running matching.")

    records: list[MatchRecord] = []
    for submission in dataset.submissions:
        ranked = rank_candidates(submission.student_name, roster)
        top_candidates = ranked[:3]
        top_candidate = top_candidates[0] if top_candidates else None
        runner_up_score = top_candidates[1].score if len(top_candidates) > 1 else None

        status = "unmatched"
        reason = "no_candidate"
        matched_user_id = None
        matched_student_name = None
        match_score = None

        if top_candidate is not None:
            matched_user_id = top_candidate.user_id
            matched_student_name = top_candidate.name
            match_score = top_candidate.score
            status, reason = _classify_match(
                top_candidate=top_candidate,
                runner_up_score=runner_up_score,
                local_name=submission.student_name,
                requires_review=submission.name_needs_review,
                config=config,
            )

        records.append(
            MatchRecord(
                local_submission_id=submission.submission_id,
                local_student_name=submission.student_name,
                total_score=submission.total_score,
                max_score=submission.max_score,
                pdf_path=submission.pdf_path,
                name_needs_review=submission.name_needs_review,
                teacher_reviewed=submission.teacher_reviewed,
                status=status,
                reason=reason,
                matched_user_id=matched_user_id,
                matched_student_name=matched_student_name,
                match_score=match_score,
                runner_up_score=runner_up_score,
                candidates=top_candidates,
            )
        )

    _flag_duplicate_auto_matches(records)

    match_dir = run_dir / "match"
    match_dir.mkdir(parents=True, exist_ok=True)
    write_match_manifest(records, match_dir / "match_manifest.json", match_dir / "match_manifest.csv")
    return records


def rank_candidates(local_name: str, roster: list[CanvasStudent]) -> list[MatchCandidate]:
    scored: list[MatchCandidate] = []
    for student in roster:
        score, reason = score_name_match(local_name, student.name)
        scored.append(
            MatchCandidate(
                user_id=student.user_id,
                name=student.name,
                score=score,
                reason=reason,
                sis_user_id=student.sis_user_id,
                login_id=student.login_id,
                section=student.section,
            )
        )
    return sorted(scored, key=lambda candidate: (-candidate.score, candidate.name.casefold(), candidate.user_id))


def score_name_match(left: str, right: str) -> tuple[int, str]:
    left_norm = normalize_name(left)
    right_norm = normalize_name(right)
    left_ascii = ascii_fold(left_norm)
    right_ascii = ascii_fold(right_norm)
    left_token_sort = " ".join(sorted(left_norm.split()))
    right_token_sort = " ".join(sorted(right_norm.split()))

    if left_norm and left_norm == right_norm:
        return 100, "exact_normalized"
    if left_ascii and left_ascii == right_ascii:
        return 100, "exact_ascii"
    if left_token_sort and left_token_sort == right_token_sort:
        return 98, "exact_token_set"

    scores = {
        "fuzzy_full": round(SequenceMatcher(None, left_norm, right_norm).ratio() * 100),
        "fuzzy_ascii": round(SequenceMatcher(None, left_ascii, right_ascii).ratio() * 100),
        "fuzzy_token_sort": round(SequenceMatcher(None, left_token_sort, right_token_sort).ratio() * 100),
    }
    reason, score = max(scores.items(), key=lambda item: (item[1], item[0]))
    return int(score), reason


def normalize_name(value: str) -> str:
    folded = unicodedata.normalize("NFKC", value).casefold()
    folded = re.sub(r"[^0-9a-z\s]", " ", folded)
    return re.sub(r"\s+", " ", folded).strip()


def ascii_fold(value: str) -> str:
    return (
        unicodedata.normalize("NFKD", value)
        .encode("ascii", "ignore")
        .decode("ascii")
        .strip()
    )


def write_match_manifest(records: list[MatchRecord], json_path: Path, csv_path: Path) -> None:
    with json_path.open("w", encoding="utf-8") as handle:
        json.dump([record.to_dict() for record in records], handle, indent=2, sort_keys=True)
        handle.write("\n")

    fieldnames = [
        "local_submission_id",
        "local_student_name",
        "total_score",
        "max_score",
        "name_needs_review",
        "teacher_reviewed",
        "status",
        "reason",
        "matched_user_id",
        "matched_student_name",
        "match_score",
        "runner_up_score",
        "candidate1_user_id",
        "candidate1_name",
        "candidate1_score",
        "candidate1_reason",
        "candidate2_user_id",
        "candidate2_name",
        "candidate2_score",
        "candidate2_reason",
        "candidate3_user_id",
        "candidate3_name",
        "candidate3_score",
        "candidate3_reason",
        "reviewer_decision",
        "reviewer_selected_user_id",
        "reviewer_note",
        "pdf_path",
    ]
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for record in records:
            row = {
                "local_submission_id": record.local_submission_id,
                "local_student_name": record.local_student_name,
                "total_score": _format_score(record.total_score),
                "max_score": _format_score(record.max_score),
                "name_needs_review": "yes" if record.name_needs_review else "no",
                "teacher_reviewed": "yes" if record.teacher_reviewed else "no",
                "status": record.status,
                "reason": record.reason,
                "matched_user_id": record.matched_user_id or "",
                "matched_student_name": record.matched_student_name or "",
                "match_score": record.match_score or "",
                "runner_up_score": record.runner_up_score or "",
                "reviewer_decision": record.reviewer_decision,
                "reviewer_selected_user_id": record.reviewer_selected_user_id or "",
                "reviewer_note": record.reviewer_note,
                "pdf_path": record.pdf_path,
            }
            for index in range(3):
                candidate = record.candidates[index] if index < len(record.candidates) else None
                row[f"candidate{index + 1}_user_id"] = candidate.user_id if candidate else ""
                row[f"candidate{index + 1}_name"] = candidate.name if candidate else ""
                row[f"candidate{index + 1}_score"] = candidate.score if candidate else ""
                row[f"candidate{index + 1}_reason"] = candidate.reason if candidate else ""
            writer.writerow(row)


def load_match_manifest(path: Path) -> list[MatchRecord]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return [MatchRecord.from_dict(row) for row in payload]


def write_locked_manifest(records: list[LockedMatchRecord], json_path: Path, csv_path: Path) -> None:
    with json_path.open("w", encoding="utf-8") as handle:
        json.dump([record.to_dict() for record in records], handle, indent=2, sort_keys=True)
        handle.write("\n")

    fieldnames = [
        "local_submission_id",
        "local_student_name",
        "total_score",
        "max_score",
        "final_status",
        "final_user_id",
        "final_student_name",
        "final_sis_user_id",
        "final_login_id",
        "final_section",
        "source_status",
        "source_reason",
        "reviewer_note",
        "pdf_path",
    ]
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for record in records:
            writer.writerow(
                {
                    "local_submission_id": record.local_submission_id,
                    "local_student_name": record.local_student_name,
                    "total_score": _format_score(record.total_score),
                    "max_score": _format_score(record.max_score),
                    "final_status": record.final_status,
                    "final_user_id": record.final_user_id or "",
                    "final_student_name": record.final_student_name or "",
                    "final_sis_user_id": record.final_sis_user_id,
                    "final_login_id": record.final_login_id,
                    "final_section": record.final_section,
                    "source_status": record.source_status,
                    "source_reason": record.source_reason,
                    "reviewer_note": record.reviewer_note,
                    "pdf_path": record.pdf_path,
                }
            )


def load_locked_manifest(path: Path) -> list[LockedMatchRecord]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return [LockedMatchRecord.from_dict(row) for row in payload]


def summarize_match_records(records: list[MatchRecord]) -> dict[str, int]:
    summary = {"auto": 0, "needs_review": 0, "unmatched": 0, "duplicate_candidate": 0}
    for record in records:
        summary[record.status] = summary.get(record.status, 0) + 1
    return summary


def summarize_locked_records(records: list[LockedMatchRecord]) -> dict[str, int]:
    summary = {"matched": 0, "skipped": 0}
    for record in records:
        summary[record.final_status] = summary.get(record.final_status, 0) + 1
    return summary


def _classify_match(
    top_candidate: MatchCandidate,
    runner_up_score: int | None,
    local_name: str,
    requires_review: bool,
    config: CanvasConnectConfig,
) -> tuple[str, str]:
    if requires_review:
        return "needs_review", "name_needs_review"

    local_norm = normalize_name(local_name)
    matched_norm = normalize_name(top_candidate.name)
    if local_norm == matched_norm or top_candidate.reason.startswith("exact_"):
        return "auto", top_candidate.reason

    margin = top_candidate.score - (runner_up_score or 0)
    if top_candidate.score >= config.match_auto_accept_score and margin >= config.match_margin:
        return "auto", top_candidate.reason
    if top_candidate.score >= config.match_review_floor:
        return "needs_review", top_candidate.reason
    return "unmatched", top_candidate.reason


def _flag_duplicate_auto_matches(records: list[MatchRecord]) -> None:
    claimed: dict[int, list[MatchRecord]] = {}
    for record in records:
        if record.status != "auto" or record.matched_user_id is None:
            continue
        claimed.setdefault(record.matched_user_id, []).append(record)

    for duplicates in claimed.values():
        if len(duplicates) < 2:
            continue
        for record in duplicates:
            record.status = "duplicate_candidate"
            record.reason = "duplicate_auto_match"


def _format_score(value: float) -> str:
    numeric = float(value)
    return str(int(numeric)) if numeric.is_integer() else f"{numeric:.2f}".rstrip("0").rstrip(".")
