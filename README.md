# HomeworkGrader

Private iPhone-only prototype for generating answer keys from blank assignments and grading scanned student work with the OpenAI `Responses` API.

## Requirements

- Xcode 15.4 or newer
- iPhone running iOS 17 or newer
- Your own OpenAI API key

## Open in Xcode

1. Open `HomeworkGrader.xcodeproj` in Xcode.
2. In Xcode, set your Apple ID/team for signing.
3. Connect your iPhone and choose it as the run destination.
4. Build and run.

If you want terminal builds, point the shell at full Xcode first:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## First Run

1. Open `Settings`.
2. Paste your OpenAI API key.
3. Create a new grading session.
4. Pick one model for answer generation and one for grading.
5. Scan the blank assignment, review the generated rubric, and enter max points for each question.
6. Scan each student's multi-page submission and review the graded result before saving.

## Notes

- This app sends scanned pages directly to OpenAI from the phone using your API key.
- The key is stored in the iOS Keychain.
- This is suitable for personal prototype use, not public distribution.
