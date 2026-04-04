from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class LocalSubmission:
    submission_id: str
    folder_name: str
    student_name: str
    total_score: float
    max_score: float
    teacher_reviewed: bool
    name_needs_review: bool
    created_at: str | None
    overall_notes: str
    scan_paths: list[str]
    pdf_path: str
    grades: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class LocalDataset:
    export_paths: list[str]
    title: str
    created_at: str | None
    question_count: int
    total_points: float
    submissions: list[LocalSubmission]

    def to_dict(self) -> dict[str, Any]:
        return {
            "export_paths": self.export_paths,
            "title": self.title,
            "created_at": self.created_at,
            "question_count": self.question_count,
            "total_points": self.total_points,
            "submissions": [submission.to_dict() for submission in self.submissions],
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "LocalDataset":
        export_paths = payload.get("export_paths")
        if export_paths is None:
            export_path = payload.get("export_path", "")
            export_paths = [export_path] if export_path else []
        return cls(
            export_paths=list(export_paths),
            title=payload["title"],
            created_at=payload.get("created_at"),
            question_count=int(payload.get("question_count", 0)),
            total_points=float(payload.get("total_points", 0)),
            submissions=[LocalSubmission(**submission) for submission in payload["submissions"]],
        )


@dataclass
class CanvasStudent:
    user_id: int
    name: str
    sortable_name: str = ""
    short_name: str = ""
    sis_user_id: str = ""
    login_id: str = ""
    section: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "CanvasStudent":
        return cls(
            user_id=int(payload["user_id"]),
            name=payload["name"],
            sortable_name=payload.get("sortable_name", ""),
            short_name=payload.get("short_name", ""),
            sis_user_id=payload.get("sis_user_id", "") or "",
            login_id=payload.get("login_id", "") or "",
            section=payload.get("section", "") or "",
        )


@dataclass
class MatchCandidate:
    user_id: int
    name: str
    score: int
    reason: str
    sis_user_id: str = ""
    login_id: str = ""
    section: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "MatchCandidate":
        return cls(
            user_id=int(payload["user_id"]),
            name=payload["name"],
            score=int(payload["score"]),
            reason=payload["reason"],
            sis_user_id=payload.get("sis_user_id", "") or "",
            login_id=payload.get("login_id", "") or "",
            section=payload.get("section", "") or "",
        )


@dataclass
class MatchRecord:
    local_submission_id: str
    local_student_name: str
    total_score: float
    max_score: float
    pdf_path: str
    first_scan_path: str
    name_needs_review: bool
    teacher_reviewed: bool
    status: str
    reason: str
    matched_user_id: int | None
    matched_student_name: str | None
    match_score: int | None
    runner_up_score: int | None
    candidates: list[MatchCandidate] = field(default_factory=list)
    reviewer_decision: str = ""
    reviewer_selected_user_id: int | None = None
    reviewer_note: str = ""

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["candidates"] = [candidate.to_dict() for candidate in self.candidates]
        return payload

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "MatchRecord":
        return cls(
            local_submission_id=payload["local_submission_id"],
            local_student_name=payload["local_student_name"],
            total_score=float(payload["total_score"]),
            max_score=float(payload["max_score"]),
            pdf_path=payload["pdf_path"],
            first_scan_path=payload.get("first_scan_path", ""),
            name_needs_review=bool(payload["name_needs_review"]),
            teacher_reviewed=bool(payload["teacher_reviewed"]),
            status=payload["status"],
            reason=payload["reason"],
            matched_user_id=(int(payload["matched_user_id"]) if payload.get("matched_user_id") is not None else None),
            matched_student_name=payload.get("matched_student_name"),
            match_score=(int(payload["match_score"]) if payload.get("match_score") is not None else None),
            runner_up_score=(int(payload["runner_up_score"]) if payload.get("runner_up_score") is not None else None),
            candidates=[MatchCandidate.from_dict(candidate) for candidate in payload.get("candidates", [])],
            reviewer_decision=payload.get("reviewer_decision", ""),
            reviewer_selected_user_id=(
                int(payload["reviewer_selected_user_id"])
                if payload.get("reviewer_selected_user_id") is not None
                else None
            ),
            reviewer_note=payload.get("reviewer_note", ""),
        )


@dataclass
class LockedMatchRecord:
    local_submission_id: str
    local_student_name: str
    total_score: float
    max_score: float
    pdf_path: str
    first_scan_path: str
    final_status: str
    final_user_id: int | None
    final_student_name: str | None
    final_sis_user_id: str = ""
    final_login_id: str = ""
    final_section: str = ""
    source_status: str = ""
    source_reason: str = ""
    reviewer_note: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "LockedMatchRecord":
        return cls(
            local_submission_id=payload["local_submission_id"],
            local_student_name=payload["local_student_name"],
            total_score=float(payload["total_score"]),
            max_score=float(payload["max_score"]),
            pdf_path=payload["pdf_path"],
            first_scan_path=payload.get("first_scan_path", ""),
            final_status=payload["final_status"],
            final_user_id=(int(payload["final_user_id"]) if payload.get("final_user_id") is not None else None),
            final_student_name=payload.get("final_student_name"),
            final_sis_user_id=payload.get("final_sis_user_id", "") or "",
            final_login_id=payload.get("final_login_id", "") or "",
            final_section=payload.get("final_section", "") or "",
            source_status=payload.get("source_status", ""),
            source_reason=payload.get("source_reason", ""),
            reviewer_note=payload.get("reviewer_note", ""),
        )


@dataclass
class UploadResult:
    local_submission_id: str
    local_student_name: str
    final_user_id: int | None
    final_student_name: str | None
    status: str
    step: str = ""
    file_id: int | None = None
    submission_id: int | None = None
    message: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def path_string(value: str | Path) -> str:
    return str(value) if isinstance(value, Path) else value
