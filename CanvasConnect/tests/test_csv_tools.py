import csv
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from canvas_connect.csv_tools import build_grade_import_csv, load_gradebook_roster
from canvas_connect.models import LockedMatchRecord


class CSVToolsTests(unittest.TestCase):
    def test_load_gradebook_roster_reads_canvas_columns(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            csv_path = Path(temp_dir) / "gradebook.csv"
            with csv_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=["Student Name", "Student ID", "SIS User ID", "SIS Login ID", "Section", "Exam 1"],
                )
                writer.writeheader()
                writer.writerow(
                    {
                        "Student Name": "Alice Smith",
                        "Student ID": "101",
                        "SIS User ID": "S101",
                        "SIS Login ID": "alice",
                        "Section": "001",
                        "Exam 1": "",
                    }
                )
            roster = load_gradebook_roster(csv_path)

        self.assertEqual(len(roster), 1)
        self.assertEqual(roster[0].user_id, 101)
        self.assertEqual(roster[0].login_id, "alice")

    def test_build_grade_import_updates_only_matched_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            template_path = Path(temp_dir) / "template.csv"
            with template_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=["Student Name", "Student ID", "Section", "Exam 1"],
                )
                writer.writeheader()
                writer.writerow({"Student Name": "Alice Smith", "Student ID": "101", "Section": "001", "Exam 1": ""})
                writer.writerow({"Student Name": "Bob Jones", "Student ID": "102", "Section": "001", "Exam 1": ""})

            output_path = Path(temp_dir) / "output.csv"
            stats = build_grade_import_csv(
                template_path,
                output_path,
                "Exam 1",
                [
                    LockedMatchRecord(
                        local_submission_id="1",
                        local_student_name="Alice Smith",
                        total_score=9,
                        max_score=10,
                        pdf_path="/tmp/alice.pdf",
                        final_status="matched",
                        final_user_id=101,
                        final_student_name="Alice Smith",
                    ),
                    LockedMatchRecord(
                        local_submission_id="2",
                        local_student_name="Ghost Student",
                        total_score=7,
                        max_score=10,
                        pdf_path="/tmp/ghost.pdf",
                        final_status="skipped",
                        final_user_id=None,
                        final_student_name=None,
                    ),
                ],
            )
            with output_path.open("r", encoding="utf-8", newline="") as handle:
                rows = list(csv.DictReader(handle))

        self.assertEqual(stats["updated_rows"], 1)
        self.assertEqual(rows[0]["Exam 1"], "9")
        self.assertEqual(rows[1]["Exam 1"], "")
