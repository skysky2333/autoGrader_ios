# HGrader + CanvasConnect

This repo contains two tools that are meant to be used together:

- `HGrader`: an iPhone app for scanning a blank assignment, generating a rubric/answer key with OpenAI, grading student scans, reviewing results, and exporting the finished session.
- `CanvasConnect`: a Python CLI that takes an `HGrader` full export, matches students to a Canvas roster, then generates a Gradebook import CSV or posts grades and uploads scanned PDFs through the Canvas API.

The Xcode project is still named `HomeworkGrader`, but the app UI is labeled `HGrader`.

## Which Tool Should You Use?

- Use `HGrader` when you want to scan and grade work on your phone.
- Use `CanvasConnect` when you are finished grading and want to move scores and scanned PDFs into Canvas.

## Quick Start

### HGrader

Requirements:

- Xcode 15.4 or newer
- iPhone running iOS 17 or newer
- Your own OpenAI API key

Open and run:

1. Open `HomeworkGrader.xcodeproj` in Xcode.
2. Set your signing team.
3. Choose a physical iPhone as the run destination.
4. Build and run.

First grading workflow:

1. Open `Settings` and save your OpenAI API key.
2. Create a new session.
3. Choose an answer-generation model and a grading model.
4. Scan the blank assignment.
5. Review and approve the generated rubric on the `Rubric` tab.
6. Grade students with either `Scan Student Submission` or `Batch Scan Submissions`.
7. Review saved results in the `Results` tab.
8. Use `Export Full Session Package` when you want to hand the session off to `CanvasConnect`.

Important notes:

- `HGrader` sends scanned pages directly from the phone to OpenAI.
- The API key is stored in the iOS Keychain.
- `Export Full Session Package` creates a ZIP file. `CanvasConnect` expects the extracted folder inside that ZIP, not the ZIP itself.

### CanvasConnect

Requirements:

- Python 3.11 or newer
- A completed `HGrader` full export, extracted to a folder
- A Canvas assignment you created manually if you want API grade posting or PDF upload
- A Canvas API token if you want live roster loading, API grade posting, or PDF upload

Recommended setup:

1. Copy `CanvasConnect/config.example.toml` to `CanvasConnect/config.toml`.
2. Point `export_paths` at the extracted `HGrader` export folder.
3. Fill in `canvas_base_url`, `course_id`, and `assignment_id`.
4. Export your Canvas token into the environment variable named by `token_env_var`.
5. Create the Canvas assignment as an unpublished assignment that allows `File Uploads`.

Typical run:

```sh
./CanvasConnect/canvas-connect run \
  --config CanvasConnect/config.toml \
  --grade-via-api
```

That run will:

- inspect the `HGrader` export
- build one PDF per local submission
- load a Canvas roster
- fuzzy-match local student names to Canvas students
- stop for interactive review when a match is uncertain
- post grades through the Canvas API
- upload PDFs as student submissions
- lock the assignment after upload if configured

If you want a Canvas Gradebook import CSV instead of live API grade posting, provide a Gradebook CSV and do not use `--grade-via-api`.

## Most Important Workflow Decisions

- Use single-student scanning when you want to review and save each student immediately.
- Use batch scanning when you want to capture many papers quickly and let grading finish later.
- Turn on the validation model when you want a second model to verify grading and flag uncertain results.
- Use `Export Session CSV` for a simple score sheet.
- Use `Export Full Session Package` when you need scans, rubric data, JSON summaries, or Canvas upload support.
- Pass `--skip-upload` to `CanvasConnect` if you only want grade output and do not want to upload PDFs.

## Canvas Assignment Safety Rules

`CanvasConnect` assumes you are trying to keep scanned exams hidden until you are ready. By default it expects:

- an assignment that already exists
- the assignment to be unpublished before upload
- `File Uploads` enabled
- manual grade posting enabled after upload
- the assignment to be locked after upload

If you only want a Gradebook CSV and do not need API posting or upload, you can avoid those live-assignment requirements by using the CSV import path.

## Repo Layout

- `HomeworkGrader/`: SwiftUI iPhone app source
- `CanvasConnect/`: Python CLI and tests
- `doc/HGrader/`: detailed user-facing documentation for the app
- `doc/CanvasConnect/`: detailed user-facing documentation for the Canvas tool

## Detailed Docs

- [Documentation Index](doc/README.md)
- [HGrader Guide](doc/HGrader/README.md)
- [CanvasConnect Guide](doc/CanvasConnect/README.md)
