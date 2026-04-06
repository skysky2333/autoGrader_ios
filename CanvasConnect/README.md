# Canvas Connect

`CanvasConnect` is a no-dependency Python CLI for taking a `HomeworkGrader` export,
matching students against a Canvas roster, generating a Gradebook import CSV or
posting grades through the Canvas API, and uploading each student's scanned exam
to a manually created Canvas assignment on their behalf.

## Workflow

1. Create the Canvas assignment manually. For the current fallback workflow, use an assignment such as `On Paper`.
2. Set the assignment posting policy to manual if you want grades hidden until you explicitly release them.
3. Export your graded session from `HomeworkGrader`.
4. Download a Canvas Gradebook CSV if you want a Gradebook import file.
5. Run the staged pipeline:

```sh
./CanvasConnect/canvas-connect run \
  --config CanvasConnect/config.toml \
  --grade-via-api
```

The run will:

- build one PDF per local submission from exported scan images
- fetch or load the Canvas roster
- rank fuzzy student-name matches and stop for manual confirmation when needed
- allow a manual name correction loop that re-runs matching immediately
- either generate a Canvas Gradebook import CSV or post grades directly through the Canvas API
- optionally upload PDFs as comment attachments and update grades through the Canvas API
- keep manual grade posting enabled when configured
- abort immediately if duplicate local student names are detected, including after a manual name correction

## Release Model

For the current on-paper fallback workflow:

- `upload-submissions` attaches each scanned PDF as a submission comment attachment
- `upload-submissions` can also update the grade in the same request
- `post-grades` remains available as a separate grade-only bulk action
- `enforce_manual_post_policy=true` keeps grades hidden until you explicitly post them in Canvas

Recommended manual workflow:

1. Create and publish the assignment if your Canvas instance requires published assignments for grade entry.
2. Set the assignment posting policy to manual.
3. Run `CanvasConnect`.
4. Verify the comments and grades as an instructor.
5. Post grades manually when you are ready for students to see them.

## Commands

- `inspect-export`
- `load-roster`
- `match`
- `review-matches`
- `build-grade-csv`
- `post-grades`
- `upload-submissions`
- `run`

For a command reference:

```sh
./CanvasConnect/canvas-connect --help
./CanvasConnect/canvas-connect run --help
```

## Config

Copy `CanvasConnect/config.example.toml` to `CanvasConnect/config.toml` and fill in
your course-specific values. Set one or more export directories in `export_paths`.
The upload payload is configurable with:
- `upload_attach_pdf_as_comment`
- `upload_post_grade`
- `upload_comment_enabled`
- `upload_comment_include_total_score`
- `upload_comment_include_question_scores`
- `upload_comment_include_individual_notes`
- `upload_comment_include_overall_notes`

Test mode:
- set `test_student_id` in config
- run `upload-submissions --test-student-only` or `post-grades --test-student-only`
- optionally set `test_source_local_submission_id` or pass `--test-source-submission-id`
- if no explicit source is set, CanvasConnect replays the first matched submission deterministically
