# HGrader + CanvasConnect

> **A note on quality.** This project was built for my own daily use, not as a demo. While AI was used heavily during development, every line ships with intent — async task management for all heavy work, careful memory and image lifecycle handling, thorough testing, and deliberate UI/UX decisions. For an iOS app, none of that is optional: the experience must be fluid, the app must stay snappy under load, and it must never crash. This is not vibe-coded junk.

Fully open-source tools for AI-powered assignment grading and Canvas LMS integration.

- **HGrader**: an iPhone app that scans paper assignments, generates rubrics with multimodal AI, and batch-grades entire stacks of student work — any subject, any handwriting, any layout.
- **CanvasConnect**: a zero-dependency Python CLI that takes HGrader exports, fuzzy-matches students to a Canvas roster, posts grades via the Canvas API, and attaches scanned PDFs as submission comments.

📖 **[Documentation website →](https://skysky2333.github.io/autoGrader_ios/)**

## Key Features

- **Any subject, any handwriting** — frontier multimodal models understand calculus, chemistry, essays, diagrams, foreign languages, and messy or chaotic layouts out of the box.
- **Built-in LaTeX rendering** — AI feedback and rubric answers are rendered with MathJax for proper mathematical notation.
- **Standalone & private** — HGrader runs entirely on your iPhone with your own OpenAI API key. Student data never touches a third-party server.
- **Batch processing** — scan an entire stack of papers and let AI grade them asynchronously via the OpenAI Batch API (50% cheaper than live calls).
- **Validation pipeline** — optional second-model validation reviews scores and requests regrading when needed.
- **Background refresh & notifications** — batch jobs continue in the background; local push notifications alert you when grading completes.
- **Zero-dependency CLI** — CanvasConnect uses only the Python standard library (3.11+).

## Quick Start

### HGrader

Requirements: Xcode 15.4+, iPhone running iOS 17+, your own OpenAI API key.

1. Open `HomeworkGrader.xcodeproj` in Xcode.
2. Set your signing team and choose a physical iPhone as the run destination.
3. Build and run.
4. Open **Settings** and save your OpenAI API key.
5. Create a new session, choose models, and scan the blank assignment.
6. Review and approve the AI-generated rubric.
7. **Batch scan** student submissions (recommended — single-student mode is deprecated due to long wait times with large models).
8. Review results, then export via **Export Full Session Package**.

> The API key is stored in the iOS Keychain and never leaves the device. Exports contain only grades, rubric data, and scan images.

### CanvasConnect

Requirements: Python 3.11+, a completed HGrader export (extracted folder), a Canvas API token.

```sh
# 1. Copy and edit the config
cp CanvasConnect/config.example.toml CanvasConnect/config.toml

# 2. Set your Canvas token
export CANVAS_API_TOKEN="your_token_here"

# 3. Run the full pipeline
./CanvasConnect/canvas-connect run \
  --config CanvasConnect/config.toml \
  --grade-via-api
```

This will inspect the export, build PDFs, load the Canvas roster, fuzzy-match students, post grades, and attach scanned PDFs as comment attachments. Pass `--skip-upload` to post grades only.

For a Canvas Gradebook import CSV instead of live API posting, provide `--gradebook-csv` and omit `--grade-via-api`.

## Canvas Release Model

For the current on-paper fallback workflow, CanvasConnect:

- Attaches each scanned PDF as a **submission comment attachment**
- Posts grades and structured score breakdowns in the same request
- Keeps **manual grade posting** enabled so grades stay hidden until you explicitly post them

Create an `On Paper` assignment in Canvas, set the posting policy to manual, and run the pipeline. If you only need a Gradebook CSV, no live Canvas assignment is required.

## Repo Layout

```
HomeworkGrader/           SwiftUI iPhone app source
CanvasConnect/            Python CLI and tests
docs/                     Documentation website (GitHub Pages)
```

## Documentation

The full documentation is available at **[skysky2333.github.io/autoGrader_ios](https://skysky2333.github.io/autoGrader_ios/)** and covers:

- [HGrader User Guide](https://skysky2333.github.io/autoGrader_ios/hgrader/user-guide/) — scanning, grading, review, and export
- [HGrader Developer Guide](https://skysky2333.github.io/autoGrader_ios/hgrader/developer/) — SwiftUI architecture, SwiftData models, OpenAI integration
- [CanvasConnect User Guide](https://skysky2333.github.io/autoGrader_ios/canvasconnect/user-guide/) — configuration, matching, grade posting
- [CanvasConnect Developer Guide](https://skysky2333.github.io/autoGrader_ios/canvasconnect/developer/) — pipeline design, Canvas API client, matching algorithm
- [End-to-End Workflow](https://skysky2333.github.io/autoGrader_ios/workflows/end-to-end.html) — paper assignments through to published Canvas grades

## License

This project is fully open source.
