import csv
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from canvas_connect.config import CanvasConnectConfig
from canvas_connect.pipeline import run_pipeline, validate_assignment_for_upload


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
                export_path=SAMPLE_EXPORT,
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
