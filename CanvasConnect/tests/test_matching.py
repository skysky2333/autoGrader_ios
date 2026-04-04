from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from canvas_connect.config import CanvasConnectConfig
from canvas_connect.matching import build_match_manifest, classify_match, normalize_name, score_name_match
from canvas_connect.models import CanvasStudent, LocalDataset, LocalSubmission, MatchCandidate


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
            export_paths=["/tmp/export"],
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
        self.assertEqual(records[0].first_scan_path, "")

    def test_name_review_flag_can_still_auto_accept_above_95(self) -> None:
        dataset = LocalDataset(
            export_paths=["/tmp/export"],
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

        self.assertEqual(records[0].status, "auto")
        self.assertEqual(records[0].reason, "exact_normalized")
        self.assertEqual(records[0].first_scan_path, "")

    def test_classify_match_above_90_auto_accepts_only_when_not_marked(self) -> None:
        config = CanvasConnectConfig(match_auto_accept_score=95, match_review_floor=90, match_margin=5)
        candidate = MatchCandidate(user_id=1, name="Alice Smith", score=91, reason="fuzzy_full")

        unmarked = classify_match("Alic Smth", candidate, runner_up_score=80, requires_review=False, config=config)
        marked = classify_match("Alic Smth", candidate, runner_up_score=80, requires_review=True, config=config)

        self.assertEqual(unmarked, ("auto", "fuzzy_full"))
        self.assertEqual(marked, ("needs_review", "name_needs_review"))

    def test_classify_match_95_or_below_goes_to_review(self) -> None:
        config = CanvasConnectConfig(match_auto_accept_score=95, match_review_floor=90, match_margin=5)
        candidate = MatchCandidate(user_id=1, name="Alice Smith", score=95, reason="fuzzy_full")

        result = classify_match("Alic Smth", candidate, runner_up_score=10, requires_review=False, config=config)

        self.assertEqual(result, ("auto", "fuzzy_full"))

    def test_classify_match_fails_auto_when_margin_is_too_small(self) -> None:
        config = CanvasConnectConfig(match_auto_accept_score=95, match_review_floor=90, match_margin=5)
        candidate = MatchCandidate(user_id=1, name="Alice Smith", score=97, reason="fuzzy_full")

        result = classify_match("Alic Smth", candidate, runner_up_score=94, requires_review=False, config=config)

        self.assertEqual(result, ("needs_review", "fuzzy_full"))
