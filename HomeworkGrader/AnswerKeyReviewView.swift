import SwiftUI

struct AnswerKeyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    @State private var questionDrafts: [RubricQuestionDraft]
    @State private var defaultPointsText = "1"
    @State private var overallGradingRules: String
    @State private var isSaving = false
    let pageData: [Data]
    let integerPointsOnly: Bool
    let onApprove: (String, [RubricQuestionDraft]) -> Void

    init(reviewState: RubricReviewState, integerPointsOnly: Bool, onApprove: @escaping (String, [RubricQuestionDraft]) -> Void) {
        _questionDrafts = State(initialValue: reviewState.questionDrafts)
        _overallGradingRules = State(initialValue: reviewState.overallGradingRules)
        self.pageData = reviewState.pageData
        self.integerPointsOnly = integerPointsOnly
        self.onApprove = onApprove
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Scanned Pages") {
                    ImageStripView(pageData: pageData)
                    Text(integerPointsOnly ? "Review and edit the generated answer key. Enter whole-number max points for every question before approving." : "Review and edit the generated answer key. Enter the max points for every question before approving.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Default Points") {
                    TextField("Default points per question", text: $defaultPointsText)
                        .keyboardType(integerPointsOnly ? .numberPad : .decimalPad)

                    Button("Apply To All Questions") {
                        applyDefaultPoints()
                    }
                    .disabled(PointPolicy.parse(defaultPointsText, integerOnly: integerPointsOnly) == nil)
                }

                Section("Overall Grading Rules") {
                    TextEditor(text: $overallGradingRules)
                        .frame(minHeight: 140)
                    RenderedPreviewButton(title: "Overall Grading Rules Preview", text: overallGradingRules)
                }

                ForEach($questionDrafts) { $draft in
                    Section(draft.displayLabel.isEmpty ? "Question" : draft.displayLabel) {
                        TextField("Question ID", text: $draft.questionID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Display label", text: $draft.displayLabel)
                            .textInputAutocapitalization(.words)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Prompt")
                                .font(.footnote.weight(.semibold))
                            TextEditor(text: $draft.promptText)
                                .frame(minHeight: 100)
                            RenderedPreviewButton(title: "\(draft.displayLabel) Prompt Preview", text: draft.promptText)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ideal answer")
                                .font(.footnote.weight(.semibold))
                            TextEditor(text: $draft.idealAnswer)
                                .frame(minHeight: 120)
                            RenderedPreviewButton(title: "\(draft.displayLabel) Ideal Answer Preview", text: draft.idealAnswer)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Grading criteria")
                                .font(.footnote.weight(.semibold))
                            TextEditor(text: $draft.gradingCriteria)
                                .frame(minHeight: 120)
                            RenderedPreviewButton(title: "\(draft.displayLabel) Criteria Preview", text: draft.gradingCriteria)
                        }

                        TextField("Max points", text: $draft.maxPointsText)
                            .keyboardType(integerPointsOnly ? .numberPad : .decimalPad)
                    }
                }
            }
            .navigationTitle("Approve Rubric")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        beginApprove()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Approve")
                        }
                    }
                    .disabled(!canApprove || isSaving)
                }
            }
            .keyboardDismissToolbar()
        }
        .feedbackToast()
        .activityOverlay(isPresented: isSaving, text: "Saving rubric...")
    }

    private var canApprove: Bool {
        !questionDrafts.isEmpty &&
        questionDrafts.allSatisfy {
            !$0.questionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.idealAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.gradingCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            PointPolicy.parse($0.maxPointsText, integerOnly: integerPointsOnly) != nil
        }
    }

    private func applyDefaultPoints() {
        guard let parsed = PointPolicy.parse(defaultPointsText, integerOnly: integerPointsOnly) else { return }
        let display = PointPolicy.displayText(for: parsed, integerOnly: integerPointsOnly)
        questionDrafts = questionDrafts.map { draft in
            var copy = draft
            copy.maxPointsText = display
            return copy
        }
        feedbackCenter.show("Applied \(display) points to \(questionDrafts.count) questions.")
    }

    private func beginApprove() {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            await Task.yield()
            onApprove(overallGradingRules, questionDrafts)
            isSaving = false
        }
    }
}

struct BatchScanSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pagesPerSubmissionText: String
    let onContinue: (Int) -> Void

    init(initialPagesPerSubmission: Int, onContinue: @escaping (Int) -> Void) {
        _pagesPerSubmissionText = State(initialValue: String(max(initialPagesPerSubmission, 1)))
        self.onContinue = onContinue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Batch Scan") {
                    TextField("Pages per submission", text: $pagesPerSubmissionText)
                        .keyboardType(.numberPad)

                    Text("Every student in the scan stack must have exactly this many pages. After scanning, the app will split the pages into equal-size submissions and upload them as one asynchronous OpenAI batch job. Batch jobs do not use priority processing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Batch Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        guard let pagesPerSubmission else { return }
                        onContinue(pagesPerSubmission)
                    }
                    .disabled(pagesPerSubmission == nil)
                }
            }
            .keyboardDismissToolbar()
        }
    }

    private var pagesPerSubmission: Int? {
        let trimmed = pagesPerSubmissionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }
}
