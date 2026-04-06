from __future__ import annotations

import argparse
from pathlib import Path

from .config import CanvasConnectConfig
from .pipeline import (
    build_grade_csv_step,
    inspect_export_step,
    load_roster_step,
    match_step,
    post_grades_step,
    review_matches_step,
    run_pipeline,
    upload_submissions_step,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="canvas-connect")
    parser.add_argument("--config", type=Path, help="Path to CanvasConnect TOML config.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect_parser = subparsers.add_parser("inspect-export")
    inspect_parser.add_argument("--export", type=Path, action="append")
    inspect_parser.add_argument("--run-dir", type=Path, required=True)

    roster_parser = subparsers.add_parser("load-roster")
    roster_parser.add_argument("--run-dir", type=Path, required=True)
    roster_parser.add_argument("--gradebook-csv", type=Path)

    match_parser = subparsers.add_parser("match")
    match_parser.add_argument("--run-dir", type=Path, required=True)
    match_parser.add_argument("--local-dataset", type=Path)
    match_parser.add_argument("--roster", type=Path)

    review_parser = subparsers.add_parser("review-matches")
    review_parser.add_argument("--run-dir", type=Path, required=True)
    review_parser.add_argument("--manifest", type=Path)
    review_parser.add_argument("--roster", type=Path)
    review_parser.add_argument("--yes", action="store_true")

    grade_parser = subparsers.add_parser("build-grade-csv")
    grade_parser.add_argument("--run-dir", type=Path, required=True)
    grade_parser.add_argument("--locked-manifest", type=Path)
    grade_parser.add_argument("--gradebook-csv", type=Path, required=True)
    grade_parser.add_argument("--assignment-column")

    upload_parser = subparsers.add_parser("upload-submissions")
    upload_parser.add_argument("--run-dir", type=Path, required=True)
    upload_parser.add_argument("--locked-manifest", type=Path)
    upload_parser.add_argument("--test-student-only", action="store_true")
    upload_parser.add_argument("--test-source-submission-id")
    upload_parser.add_argument("--yes", action="store_true")

    grade_api_parser = subparsers.add_parser("post-grades")
    grade_api_parser.add_argument("--run-dir", type=Path, required=True)
    grade_api_parser.add_argument("--locked-manifest", type=Path)
    grade_api_parser.add_argument("--test-student-only", action="store_true")
    grade_api_parser.add_argument("--test-source-submission-id")

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--export", type=Path, action="append")
    run_parser.add_argument("--gradebook-csv", type=Path)
    run_parser.add_argument("--assignment-column")
    run_parser.add_argument("--grade-via-api", action="store_true")
    run_parser.add_argument("--test-student-only", action="store_true")
    run_parser.add_argument("--test-source-submission-id")
    run_parser.add_argument("--skip-upload", action="store_true")
    run_parser.add_argument("--yes", action="store_true")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    config = CanvasConnectConfig.load(args.config)

    if args.command == "inspect-export":
        inspect_export_step(_resolve_export_paths(config, args.export), args.run_dir)
        return 0

    if args.command == "load-roster":
        load_roster_step(config, args.run_dir, args.gradebook_csv)
        return 0

    if args.command == "match":
        local_dataset = args.local_dataset or args.run_dir / "inspect" / "local_dataset.json"
        roster = args.roster or args.run_dir / "roster" / "roster.json"
        match_step(local_dataset, roster, config, args.run_dir)
        return 0

    if args.command == "review-matches":
        manifest = args.manifest or args.run_dir / "match" / "match_manifest.json"
        roster = args.roster or args.run_dir / "roster" / "roster.json"
        review_matches_step(manifest, roster, config, args.run_dir, assume_yes=args.yes)
        return 0

    if args.command == "build-grade-csv":
        locked_manifest = args.locked_manifest or args.run_dir / "match" / "locked_manifest.json"
        assignment_column = args.assignment_column or config.assignment_column
        if not assignment_column:
            parser.error("build-grade-csv requires --assignment-column or config.assignment_column")
        build_grade_csv_step(locked_manifest, args.gradebook_csv, assignment_column, args.run_dir)
        return 0

    if args.command == "upload-submissions":
        locked_manifest = args.locked_manifest or args.run_dir / "match" / "locked_manifest.json"
        upload_submissions_step(
            locked_manifest,
            config,
            args.run_dir,
            assume_yes=args.yes,
            test_student_only=args.test_student_only,
            test_source_submission_id=args.test_source_submission_id,
        )
        return 0

    if args.command == "post-grades":
        locked_manifest = args.locked_manifest or args.run_dir / "match" / "locked_manifest.json"
        post_grades_step(
            locked_manifest,
            config,
            args.run_dir,
            test_student_only=args.test_student_only,
            test_source_submission_id=args.test_source_submission_id,
        )
        return 0

    if args.command == "run":
        run_pipeline(
            export_paths=_resolve_export_paths(config, args.export),
            config=config,
            gradebook_csv=args.gradebook_csv,
            assignment_column=args.assignment_column,
            grade_via_api=args.grade_via_api,
            test_student_only=args.test_student_only,
            test_source_submission_id=args.test_source_submission_id,
            upload_submissions=not args.skip_upload,
            assume_yes=args.yes,
        )
        return 0

    parser.error(f"Unknown command: {args.command}")
    return 2


def _resolve_export_paths(config: CanvasConnectConfig, cli_exports: list[Path] | None) -> list[Path]:
    if cli_exports:
        return cli_exports
    if config.export_paths:
        return [Path(path) for path in config.export_paths]
    raise SystemExit("No export paths were provided. Set export_paths in config.toml or pass --export.")
