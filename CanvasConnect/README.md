# Canvas Connect

`CanvasConnect` is a no-dependency Python CLI for taking a `HomeworkGrader` export,
matching students against a Canvas roster, generating a Gradebook import CSV, and
uploading each student's scanned exam to a manually created Canvas assignment on
their behalf.

## Workflow

1. Create the Canvas assignment manually as an online assignment with `File Uploads`.
2. Keep the assignment unpublished before running the uploader.
3. Export your graded session from `HomeworkGrader`.
4. Download a Canvas Gradebook CSV if you want a Gradebook import file.
5. Run the staged pipeline:

```sh
./CanvasConnect/canvas-connect run \
  --config CanvasConnect/config.toml \
  --export /Users/sky2333/Downloads/grading/files/Quiz2v3-2026-04-04T15-39-30Z \
  --gradebook-csv /path/to/canvas-gradebook.csv
```

The run will:

- build one PDF per local submission from exported scan images
- fetch or load the Canvas roster
- rank fuzzy student-name matches and stop for manual confirmation when needed
- generate a Canvas Gradebook import CSV
- optionally upload PDFs as student submissions through the Canvas API
- lock the assignment after upload and keep manual grade posting enabled

## Assignment Safety Model

To satisfy the "hidden after upload" and "students cannot submit their own PDF"
requirements, the uploader enforces these rules by default:

- the target assignment must already be unpublished before upload starts
- the target assignment must allow `online_upload`
- after upload, the assignment is updated to `post_manually=true`
- after upload, the assignment is locked at the current time so students cannot add
  late self-submissions if a scan was not uploaded for them

This means your manual workflow should be:

1. Create the assignment unpublished.
2. Run `CanvasConnect`.
3. Import the generated grade CSV into Canvas.
4. Publish and manually post grades later when you are ready.

## Commands

- `inspect-export`
- `load-roster`
- `match`
- `review-matches`
- `build-grade-csv`
- `upload-submissions`
- `run`

For a command reference:

```sh
./CanvasConnect/canvas-connect --help
./CanvasConnect/canvas-connect run --help
```

## Config

Copy `CanvasConnect/config.example.toml` to `CanvasConnect/config.toml` and fill in
your course-specific values.
