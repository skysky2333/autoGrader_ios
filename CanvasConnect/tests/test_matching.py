from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from canvas_connect.config import CanvasConnectConfig
from canvas_connect.matching import build_match_manifest, normalize_name, score_name_match
from canvas_connect.models import CanvasStudent, LocalDataset, LocalSubmission


class MatchingTests(unittest.TestCase):
    def test_normalize_name_collapses_case_and_punctuation(self) -> None:
        self.assertEqual(normalize_name("  Anna-Lu  "), "anna lu")
        self.assertEqual(normalize_name("SHARANYA GOSWAMI"), "sharanya goswami")

    def test_score_name_match_exact_token_set_scores_high(self) -> None:
        score, reason = score_name_match("YongQi Lin", "Lin YongQi")
        self.assertGreaterEqual(score, 98)
        self.assertIn("token", reason)

    def test_duplicate_auto_matches_are_flagged(self) -> None:
        dataset = LocalDataset(
            export_path="/tmp/export",
            title="Quiz",
            created_at=None,
            question_count=1,
            total_points=10,
            submissions=[
                LocalSubmission(
                    submission_id="1",
                    folder_name="s1",
                    student_name="Alice Smith",
                    total_score=10,
                    max_score=10,
                    teacher_reviewed=False,
                    name_needs_review=False,
                    created_at=None,
                    overall_notes="",
                    scan_paths=[],
                    pdf_path="/tmp/alice1.pdf",
                ),
                LocalSubmission(
                    submission_id="2",
                    folder_name="s2",
                    student_name="Alice Smith",
                    total_score=9,
                    max_score=10,
                    teacher_reviewed=False,
                    name_needs_review=False,
                    created_at=None,
                    overall_notes="",
                    scan_paths=[],
                    pdf_path="/tmp/alice2.pdf",
                ),
            ],
        )
        roster = [CanvasStudent(user_id=1, name="Alice Smith")]
        config = CanvasConnectConfig()

        with tempfile.TemporaryDirectory() as temp_dir:
            records = build_match_manifest(dataset, roster, config, Path(temp_dir))

        self.assertEqual([record.status for record in records], ["duplicate_candidate", "duplicate_candidate"])

    def test_name_review_flag_forces_manual_review(self) -> None:
        dataset = LocalDataset(
            export_path="/tmp/export",
            title="Quiz",
            created_at=None,
            question_count=1,
            total_points=10,
            submissions=[
                LocalSubmission(
                    submission_id="1",
                    folder_name="s1",
                    student_name="Gabriel Neuner",
                    total_score=10,
                    max_score=10,
                    teacher_reviewed=False,
                    name_needs_review=True,
                    created_at=None,
                    overall_notes="",
                    scan_paths=[],
                    pdf_path="/tmp/gabriel.pdf",
                )
            ],
        )
        roster = [CanvasStudent(user_id=2, name="Gabriel Neuner")]
        config = CanvasConnectConfig()

        with tempfile.TemporaryDirectory() as temp_dir:
            records = build_match_manifest(dataset, roster, config, Path(temp_dir))

        self.assertEqual(records[0].status, "needs_review")
        self.assertEqual(records[0].reason, "name_needs_review")
