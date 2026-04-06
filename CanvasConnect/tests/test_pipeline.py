import csv
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from canvas_connect.config import CanvasConnectConfig
from canvas_connect.models import CanvasStudent, LocalSubmission, LockedMatchRecord, MatchCandidate, MatchRecord
from canvas_connect.pipeline import (
    _prompt_for_record,
    build_execution_records,
    build_comment_text,
    run_pipeline,
    validate_assignment_for_comment_workflow,
    validate_assignment_for_grading,
    validate_assignment_for_upload,
)


SAMPLE_EXPORT = Path("/Users/sky2333/Downloads/grading/files/Quiz2v3-2026-04-04T15-39-30Z")


class PipelineTests(unittest.TestCase):
    def test_run_pipeline_dry_run_generates_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            gradebook_csv = temp_root / "gradebook.csv"
            self._write_gradebook_template(gradebook_csv)

            config = CanvasConnectConfig(
                assignment_column="Quiz 2 Upload",
                output_root=str(temp_root / "out"),
            )

            artifacts = run_pipeline(
                export_paths=[SAMPLE_EXPORT],
                config=config,
                gradebook_csv=gradebook_csv,
                assignment_column="Quiz 2 Upload",
                upload_submissions=False,
                assume_yes=True,
            )

            self.assertTrue(Path(artifacts["local_dataset"]).exists())
            self.assertTrue(Path(artifacts["roster"]).exists())
            self.assertTrue(Path(artifacts["match_manifest"]).exists())
            self.assertTrue(Path(artifacts["locked_manifest"]).exists())
            self.assertTrue(Path(artifacts["grade_csv"]).exists())

    def test_validate_assignment_requires_online_upload(self) -> None:
        config = CanvasConnectConfig()
        with self.assertRaisesRegex(ValueError, "online file uploads"):
            validate_assignment_for_upload({"submission_types": ["none"], "published": False}, config)

        validate_assignment_for_upload({"submission_types": ["online_upload"], "published": True}, config)

    def test_validate_assignment_for_comment_workflow_accepts_on_paper(self) -> None:
        config = CanvasConnectConfig()
        validate_assignment_for_comment_workflow({"id": 123, "submission_types": ["on_paper"], "published": False}, config)

    def test_validate_assignment_for_grading_requires_assignment_id(self) -> None:
        with self.assertRaisesRegex(ValueError, "assignment id"):
            validate_assignment_for_grading({})

    def test_build_execution_records_uses_test_student_and_first_source_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            roster_dir = temp_root / "roster"
            roster_dir.mkdir(parents=True, exist_ok=True)
            (roster_dir / "roster.json").write_text(
                '[{"user_id": 186642, "name": "Test Student"}]\n',
                encoding="utf-8",
            )
            locked = [
                LockedMatchRecord(
                    local_submission_id="source-1",
                    local_student_name="Alice Smith",
                    total_score=9,
                    max_score=10,
                    pdf_path="/tmp/alice.pdf",
                    first_scan_path="/tmp/alice-page-1.jpg",
                    final_status="matched",
                    final_user_id=101,
                    final_student_name="Alice Smith",
                )
            ]
            config = CanvasConnectConfig(test_student_id=186642)

            execution_records, message = build_execution_records(
                locked,
                config,
                temp_root,
                test_student_only=True,
                test_source_submission_id=None,
            )

        self.assertEqual(len(execution_records), 1)
        self.assertEqual(execution_records[0].final_user_id, 186642)
        self.assertEqual(execution_records[0].final_student_name, "Test Student")
        self.assertEqual(execution_records[0].local_submission_id, "source-1")
        self.assertIn("Alice Smith", message)

    def test_build_execution_records_can_override_source_submission_id(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            locked = [
                LockedMatchRecord(
                    local_submission_id="source-1",
                    local_student_name="Alice Smith",
                    total_score=9,
                    max_score=10,
                    pdf_path="/tmp/alice.pdf",
                    first_scan_path="/tmp/alice-page-1.jpg",
                    final_status="matched",
                    final_user_id=101,
                    final_student_name="Alice Smith",
                ),
                LockedMatchRecord(
                    local_submission_id="source-2",
                    local_student_name="Bob Jones",
                    total_score=7,
                    max_score=10,
                    pdf_path="/tmp/bob.pdf",
                    first_scan_path="/tmp/bob-page-1.jpg",
                    final_status="matched",
                    final_user_id=102,
                    final_student_name="Bob Jones",
                ),
            ]
            config = CanvasConnectConfig(test_student_id=186642)

            execution_records, _ = build_execution_records(
                locked,
                config,
                temp_root,
                test_student_only=True,
                test_source_submission_id="source-2",
            )

        self.assertEqual(execution_records[0].local_submission_id, "source-2")

    def test_prompt_for_record_candidate_choice_does_not_ask_for_note(self) -> None:
        config = CanvasConnectConfig()
        record = MatchRecord(
            local_submission_id="1",
            local_student_name="Alice Smith",
            total_score=9,
            max_score=10,
            pdf_path="/tmp/alice.pdf",
            first_scan_path="/tmp/alice-page-1.jpg",
            name_needs_review=False,
            teacher_reviewed=False,
            status="needs_review",
            reason="fuzzy_full",
            matched_user_id=101,
            matched_student_name="Alice Smith",
            match_score=95,
            runner_up_score=88,
            candidates=[MatchCandidate(user_id=101, name="Alice Smith", score=95, reason="fuzzy_full")],
        )
        roster_list = [CanvasStudent(user_id=101, name="Alice Smith")]
        roster = {101: roster_list[0]}

        with patch("builtins.input", side_effect=["1"]):
            locked = _prompt_for_record(record, roster_list, roster, {}, {"1": "Alice Smith"}, config)

        self.assertEqual(locked.final_status, "matched")
        self.assertEqual(locked.reviewer_note, "")

    def test_prompt_for_record_empty_choice_defaults_to_first_candidate(self) -> None:
        config = CanvasConnectConfig()
        record = MatchRecord(
            local_submission_id="1",
            local_student_name="Alice Smith",
            total_score=9,
            max_score=10,
            pdf_path="/tmp/alice.pdf",
            first_scan_path="/tmp/alice-page-1.jpg",
            name_needs_review=False,
            teacher_reviewed=False,
            status="needs_review",
            reason="fuzzy_full",
            matched_user_id=101,
            matched_student_name="Alice Smith",
            match_score=95,
            runner_up_score=88,
            candidates=[MatchCandidate(user_id=101, name="Alice Smith", score=95, reason="fuzzy_full")],
        )
        roster_list = [CanvasStudent(user_id=101, name="Alice Smith")]
        roster = {101: roster_list[0]}

        with patch("builtins.input", side_effect=[""]):
            locked = _prompt_for_record(record, roster_list, roster, {}, {"1": "Alice Smith"}, config)

        self.assertEqual(locked.final_status, "matched")
        self.assertEqual(locked.final_user_id, 101)

    def test_prompt_for_record_uncertain_choice_asks_for_note(self) -> None:
        config = CanvasConnectConfig()
        record = MatchRecord(
            local_submission_id="1",
            local_student_name="Alice Smith",
            total_score=9,
            max_score=10,
            pdf_path="/tmp/alice.pdf",
            first_scan_path="/tmp/alice-page-1.jpg",
            name_needs_review=False,
            teacher_reviewed=False,
            status="needs_review",
            reason="fuzzy_full",
            matched_user_id=101,
            matched_student_name="Alice Smith",
            match_score=95,
            runner_up_score=88,
            candidates=[MatchCandidate(user_id=101, name="Alice Smith", score=95, reason="fuzzy_full")],
        )
        roster_list = [CanvasStudent(user_id=101, name="Alice Smith")]
        roster = {101: roster_list[0]}

        with patch("builtins.input", side_effect=["s", "handwriting unclear"]):
            locked = _prompt_for_record(record, roster_list, roster, {}, {"1": "Alice Smith"}, config)

        self.assertEqual(locked.final_status, "skipped")
        self.assertEqual(locked.reviewer_note, "handwriting unclear")

    def test_prompt_for_record_rename_can_auto_match_and_continue(self) -> None:
        config = CanvasConnectConfig()
        roster_list = [
            CanvasStudent(user_id=101, name="Alice Smith"),
            CanvasStudent(user_id=102, name="Bob Jones"),
        ]
        roster = {student.user_id: student for student in roster_list}
        record = MatchRecord(
            local_submission_id="1",
            local_student_name="Alic Smth",
            total_score=9,
            max_score=10,
            pdf_path="/tmp/alice.pdf",
            first_scan_path="/tmp/alice-page-1.jpg",
            name_needs_review=False,
            teacher_reviewed=False,
            status="needs_review",
            reason="fuzzy_full",
            matched_user_id=None,
            matched_student_name=None,
            match_score=None,
            runner_up_score=None,
            candidates=[],
        )

        with patch("builtins.input", side_effect=["r", "Alice Smith"]):
            locked = _prompt_for_record(record, roster_list, roster, {}, {"1": "Alic Smth"}, config)

        self.assertEqual(locked.final_status, "matched")
        self.assertEqual(locked.local_student_name, "Alice Smith")
        self.assertEqual(locked.final_user_id, 101)

    def test_prompt_for_record_rename_duplicate_name_errors(self) -> None:
        config = CanvasConnectConfig()
        roster_list = [CanvasStudent(user_id=101, name="Alice Smith")]
        roster = {student.user_id: student for student in roster_list}
        record = MatchRecord(
            local_submission_id="1",
            local_student_name="Alic Smth",
            total_score=9,
            max_score=10,
            pdf_path="/tmp/alice.pdf",
            first_scan_path="/tmp/alice-page-1.jpg",
            name_needs_review=False,
            teacher_reviewed=False,
            status="needs_review",
            reason="fuzzy_full",
            matched_user_id=None,
            matched_student_name=None,
            match_score=None,
            runner_up_score=None,
            candidates=[],
        )

        with patch("builtins.input", side_effect=["r", "Bob Jones"]):
            with self.assertRaisesRegex(ValueError, "Duplicate student names detected"):
                _prompt_for_record(
                    record,
                    roster_list,
                    roster,
                    {},
                    {"1": "Alic Smth", "2": "Bob Jones"},
                    config,
                )

    def test_build_comment_text_includes_total_and_question_scores(self) -> None:
        submission = LocalSubmission(
            submission_id="1",
            folder_name="s1",
            student_name="Alice Smith",
            total_score=9,
            max_score=10,
            teacher_reviewed=False,
            name_needs_review=False,
            created_at=None,
            overall_notes="Strong work overall.",
            scan_paths=["/tmp/alice-page-1.jpg"],
            pdf_path="/tmp/alice.pdf",
            grades=[
                {"displayLabel": "1", "awardedPoints": 2, "maxPoints": 2, "feedback": "Correct setup and answer."},
                {"displayLabel": "2", "awardedPoints": 1, "maxPoints": 2, "feedback": "Arithmetic slip in the final line."},
            ],
        )

        text = build_comment_text(submission, CanvasConnectConfig())

        self.assertIn("Total Score: 9/10", text)
        self.assertIn("- 1: 2/2", text)
        self.assertIn("- 2: 1/2", text)
        self.assertIn("Strong work overall.", text)

    def test_build_comment_text_respects_config_toggles(self) -> None:
        submission = LocalSubmission(
            submission_id="1",
            folder_name="s1",
            student_name="Alice Smith",
            total_score=9,
            max_score=10,
            teacher_reviewed=False,
            name_needs_review=False,
            created_at=None,
            overall_notes="Strong work overall.",
            scan_paths=["/tmp/alice-page-1.jpg"],
            pdf_path="/tmp/alice.pdf",
            grades=[{"displayLabel": "1", "awardedPoints": 2, "maxPoints": 2, "feedback": "Correct setup and answer."}],
        )
        config = CanvasConnectConfig(
            upload_comment_enabled=True,
            upload_comment_include_total_score=False,
            upload_comment_include_question_scores=False,
            upload_comment_include_individual_notes=False,
            upload_comment_include_overall_notes=True,
        )

        text = build_comment_text(submission, config)

        self.assertNotIn("Total Score:", text)
        self.assertNotIn("Question Scores:", text)
        self.assertIn("Strong work overall.", text)

    def test_build_comment_text_can_include_individual_notes(self) -> None:
        submission = LocalSubmission(
            submission_id="1",
            folder_name="s1",
            student_name="Alice Smith",
            total_score=9,
            max_score=10,
            teacher_reviewed=False,
            name_needs_review=False,
            created_at=None,
            overall_notes="Strong work overall.",
            scan_paths=["/tmp/alice-page-1.jpg"],
            pdf_path="/tmp/alice.pdf",
            grades=[
                {"displayLabel": "1", "awardedPoints": 2, "maxPoints": 2, "feedback": "Correct setup and answer."},
                {"displayLabel": "2", "awardedPoints": 1, "maxPoints": 2, "feedback": "Arithmetic slip in the final line."},
            ],
        )
        config = CanvasConnectConfig(
            upload_comment_enabled=True,
            upload_comment_include_total_score=False,
            upload_comment_include_question_scores=False,
            upload_comment_include_individual_notes=True,
            upload_comment_include_overall_notes=False,
        )

        text = build_comment_text(submission, config)

        self.assertIn("Individual Notes:", text)
        self.assertIn("- 1: Correct setup and answer.", text)
        self.assertIn("- 2: Arithmetic slip in the final line.", text)

    def _write_gradebook_template(self, path: Path) -> None:
        with path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=["Student Name", "Student ID", "SIS User ID", "SIS Login ID", "Section", "Quiz 2 Upload"],
            )
            writer.writeheader()
            with (SAMPLE_EXPORT / "session.csv").open("r", encoding="utf-8", newline="") as source:
                for index, row in enumerate(csv.DictReader(source), start=1000):
                    writer.writerow(
                        {
                            "Student Name": row["Student Name"],
                            "Student ID": str(index),
                            "SIS User ID": "",
                            "SIS Login ID": row["Student Name"].lower().replace(" ", "_"),
                            "Section": "001",
                            "Quiz 2 Upload": "",
                        }
                    )
