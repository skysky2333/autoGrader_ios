from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import tomllib


@dataclass
class CanvasConnectConfig:
    export_paths: list[str] = field(default_factory=list)
    canvas_base_url: str = ""
    course_id: int | None = None
    assignment_id: int | None = None
    token_env_var: str = "CANVAS_API_TOKEN"
    assignment_column: str = ""
    output_root: str = "CanvasConnect/output"
    match_auto_accept_score: int = 95
    match_review_floor: int = 90
    match_margin: int = 5
    require_unpublished_assignment: bool = True
    lock_assignment_after_upload: bool = True
    enforce_manual_post_policy: bool = True
    request_timeout_seconds: int = 60

    @classmethod
    def load(cls, path: Path | None) -> "CanvasConnectConfig":
        if path is None:
            return cls()
        with path.open("rb") as handle:
            payload = tomllib.load(handle)
        return cls(
            export_paths=_load_export_paths(payload),
            canvas_base_url=payload.get("canvas_base_url", ""),
            course_id=payload.get("course_id"),
            assignment_id=payload.get("assignment_id"),
            token_env_var=payload.get("token_env_var", "CANVAS_API_TOKEN"),
            assignment_column=payload.get("assignment_column", ""),
            output_root=payload.get("output_root", "CanvasConnect/output"),
            match_auto_accept_score=int(payload.get("match_auto_accept_score", 95)),
            match_review_floor=int(payload.get("match_review_floor", 90)),
            match_margin=int(payload.get("match_margin", 5)),
            require_unpublished_assignment=bool(payload.get("require_unpublished_assignment", True)),
            lock_assignment_after_upload=bool(payload.get("lock_assignment_after_upload", True)),
            enforce_manual_post_policy=bool(payload.get("enforce_manual_post_policy", True)),
            request_timeout_seconds=int(payload.get("request_timeout_seconds", 60)),
        )


def _load_export_paths(payload: dict) -> list[str]:
    export_paths = payload.get("export_paths")
    if export_paths is None:
        export_path = payload.get("export_path")
        if export_path:
            return [str(export_path)]
        return []
    return [str(path) for path in export_paths]
