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
from canvas_connect.models import CanvasStudent, MatchCandidate, MatchRecord
from canvas_connect.pipeline import _prompt_for_record, run_pipeline, validate_assignment_for_upload


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

    def test_validate_assignment_requires_unpublished_online_upload(self) -> None:
        config = CanvasConnectConfig(require_unpublished_assignment=True)
        with self.assertRaisesRegex(ValueError, "online file uploads"):
            validate_assignment_for_upload({"submission_types": ["none"], "published": False}, config)

        with self.assertRaisesRegex(ValueError, "published"):
            validate_assignment_for_upload({"submission_types": ["online_upload"], "published": True}, config)

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
