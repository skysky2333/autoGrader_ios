from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from canvas_connect.export_parser import inspect_export


SAMPLE_EXPORT = Path("/Users/sky2333/Downloads/grading/files/Quiz2v3-2026-04-04T15-39-30Z")


class ExportParserTests(unittest.TestCase):
    def test_inspect_export_builds_dataset_and_pdfs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            dataset = inspect_export(SAMPLE_EXPORT, Path(temp_dir))
            self.assertEqual(dataset.title, "Quiz2v3")
            self.assertEqual(len(dataset.submissions), 28)
            self.assertTrue(all(Path(submission.pdf_path).exists() for submission in dataset.submissions))
            first_pdf = Path(dataset.submissions[0].pdf_path).read_bytes()
            self.assertTrue(first_pdf.startswith(b"%PDF-1.4"))
