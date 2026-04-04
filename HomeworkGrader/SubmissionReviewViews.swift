import SwiftUI

struct SubmissionDraftFormSections: View {
    @Binding var draft: SubmissionDraft
    let integerPointsOnly: Bool

    var body: some View {
        Section("Student") {
            TextField("Student name", text: $draft.studentName)
                .textInputAutocapitalization(.words)
            Toggle("Name needs review", isOn: $draft.nameNeedsReview)
            Toggle("Needs attention", isOn: $draft.needsAttention)

            if draft.nameNeedsReview {
                HighlightNotice(
                    message: "Name needs human review.",
                    color: .orange
                )
            }

            if draft.needsAttention {
                HighlightNotice(
                    message: "This submission needs teacher attention before the grade can be trusted.",
                    color: .red
                )
            }

            Text("The model extracts the name from the scanned pages. Correct it here before saving if needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if draft.requiresAttention {
                Label("Teacher review is required before saving.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }

        if draft.needsAttention || !draft.attentionReasonsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section("Attention Reasons") {
                TextEditor(text: $draft.attentionReasonsText)
                    .frame(minHeight: 120)
                RenderedPreviewButton(title: "Attention Reasons Preview", text: draft.attentionReasonsText)
            }
        }

        if !draft.pageData.isEmpty {
            Section("Scanned Pages") {
                ImageStripView(pageData: draft.pageData)
            }
        }

        Section("Scores") {
            LabeledContent("Total") {
                ScorePairText(
                    awardedPoints: draft.totalScore,
                    maxPoints: draft.maxScore
                )
                .foregroundStyle(scoreForegroundColor(awardedPoints: draft.totalScore, maxPoints: draft.maxScore))
            }
            .font(.headline)
            if integerPointsOnly {
                Text("Integer-points mode is on. Awarded scores are restricted to whole numbers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(draft.grades.indices, id: \.self) { index in
            Section {
                if gradeNeedsHighlight(draft.grades[index]) {
                    HighlightNotice(
                        message: "This answer needs human review.",
                        color: .orange
                    )
                }

                Stepper(value: $draft.grades[index].awardedPoints, in: 0...draft.grades[index].maxPoints, step: PointPolicy.step(integerOnly: integerPointsOnly)) {
                    LabeledContent("Awarded points") {
                        ScorePairText(
                            awardedPoints: draft.grades[index].awardedPoints,
                            maxPoints: draft.grades[index].maxPoints
                        )
                        .foregroundStyle(
                            scoreForegroundColor(
                                awardedPoints: draft.grades[index].awardedPoints,
                                maxPoints: draft.grades[index].maxPoints
                            )
                        )
                    }
                }

                Toggle("Final answer correct", isOn: $draft.grades[index].isAnswerCorrect)
                Toggle("Work process correct", isOn: $draft.grades[index].isProcessCorrect)
                Toggle("Needs review", isOn: $draft.grades[index].needsReview)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Feedback")
                        .font(.footnote.weight(.semibold))
                    TextEditor(text: $draft.grades[index].feedback)
                        .frame(minHeight: 100)
                    RenderedPreviewButton(title: "\(draft.grades[index].displayLabel) Feedback Preview", text: draft.grades[index].feedback)
                }
            } header: {
                GradeSectionHeader(
                    title: draft.grades[index].displayLabel,
                    isHighlighted: gradeNeedsHighlight(draft.grades[index])
                )
            }
        }

        Section("Overall Notes") {
            TextEditor(text: $draft.overallNotes)
                .frame(minHeight: 120)
            RenderedPreviewButton(title: "Overall Notes Preview", text: draft.overallNotes)
        }
    }
}

struct SubmissionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SubmissionDraft
    @State private var isSaving = false
    let integerPointsOnly: Bool
    let showsSaveAndScanNext: Bool
    let onSave: (SubmissionDraft) -> Void
    let onSaveAndScanNext: (SubmissionDraft) -> Void

    init(
        draft: SubmissionDraft,
        integerPointsOnly: Bool,
        showsSaveAndScanNext: Bool = true,
        onSave: @escaping (SubmissionDraft) -> Void,
        onSaveAndScanNext: @escaping (SubmissionDraft) -> Void
    ) {
        _draft = State(initialValue: draft.normalized(integerPointsOnly: integerPointsOnly))
        self.integerPointsOnly = integerPointsOnly
        self.showsSaveAndScanNext = showsSaveAndScanNext
        self.onSave = onSave
        self.onSaveAndScanNext = onSaveAndScanNext
    }

    var body: some View {
        NavigationStack {
            Form {
                SubmissionDraftFormSections(draft: $draft, integerPointsOnly: integerPointsOnly)
            }
            .navigationTitle("Review Grade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        beginSave(scanNext: false)
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!canSave || isSaving)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if showsSaveAndScanNext {
                        Button {
                            beginSave(scanNext: true)
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Save & Scan Next")
                            }
                        }
                        .disabled(!canSave || isSaving)
                    }
                }
            }
            .keyboardDismissToolbar()
        }
        .feedbackToast()
        .activityOverlay(isPresented: isSaving, text: "Saving submission...")
    }

    private var canSave: Bool {
        !draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.grades.isEmpty
    }

    private var normalizedDraft: SubmissionDraft {
        draft.normalized(integerPointsOnly: integerPointsOnly)
    }

    private func beginSave(scanNext: Bool) {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            await Task.yield()
            if scanNext {
                onSaveAndScanNext(normalizedDraft)
            } else {
                onSave(normalizedDraft)
            }
            isSaving = false
        }
    }
}

struct BatchSubmissionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [SubmissionDraft]
    let failures: [BatchSubmissionFailure]
    let integerPointsOnly: Bool
    let onSaveAll: ([SubmissionDraft]) -> Void

    init(
        reviewState: BatchSubmissionReviewState,
        integerPointsOnly: Bool,
        onSaveAll: @escaping ([SubmissionDraft]) -> Void
    ) {
        _drafts = State(initialValue: reviewState.drafts.map { $0.normalized(integerPointsOnly: integerPointsOnly) })
        self.failures = reviewState.failures
        self.integerPointsOnly = integerPointsOnly
        self.onSaveAll = onSaveAll
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent("Ready to save", value: "\(drafts.count)")
                    LabeledContent("Needs review", value: "\(drafts.filter(\.requiresAttention).count)")

                    if !failures.isEmpty {
                        LabeledContent("Failed", value: "\(failures.count)")
                    }

                    Text("Edit any result before saving. Nothing in this batch is stored until you tap Save All.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Submissions") {
                    ForEach(drafts.indices, id: \.self) { index in
                        NavigationLink {
                            BatchSubmissionDraftEditorView(draft: $drafts[index], integerPointsOnly: integerPointsOnly)
                        } label: {
                            SubmissionDraftSummaryRow(draft: drafts[index])
                        }
                    }
                }

                if !failures.isEmpty {
                    Section("Failed During Batch Grading") {
                        ForEach(failures) { failure in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Submission \(failure.submissionNumber)")
                                    .font(.headline)
                                Text(failure.message)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Review Batch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save All") {
                        onSaveAll(normalizedDrafts)
                    }
                    .disabled(!canSaveAll)
                }
            }
        }
        .feedbackToast()
    }

    private var canSaveAll: Bool {
        !drafts.isEmpty &&
        drafts.allSatisfy {
            !$0.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.grades.isEmpty
        }
    }

    private var normalizedDrafts: [SubmissionDraft] {
        drafts.map { $0.normalized(integerPointsOnly: integerPointsOnly) }
    }
}

struct BatchSubmissionDraftEditorView: View {
    @Binding var draft: SubmissionDraft
    let integerPointsOnly: Bool

    var body: some View {
        Form {
            SubmissionDraftFormSections(draft: $draft, integerPointsOnly: integerPointsOnly)
        }
        .navigationTitle(draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Submission" : draft.studentName)
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissToolbar()
        .feedbackToast()
    }
}
