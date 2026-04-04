import SwiftUI
import SwiftData

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

struct SubmissionDraftFormSections: View {
    @Binding var draft: SubmissionDraft
    let integerPointsOnly: Bool

    var body: some View {
        Section("Student") {
            TextField("Student name", text: $draft.studentName)
                .textInputAutocapitalization(.words)
            Toggle("Name needs review", isOn: $draft.nameNeedsReview)

            if draft.nameNeedsReview {
                HighlightNotice(
                    message: "Name needs human review.",
                    color: .orange
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

struct SavedSubmissionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    let submission: StudentSubmission
    let integerPointsOnly: Bool
    let onRegrade: (() -> Void)?
    @State private var draft: SubmissionDraft
    @State private var isSaving = false

    init(submission: StudentSubmission, onRegrade: (() -> Void)? = nil) {
        self.submission = submission
        let integerOnly = submission.session?.integerPointsOnlyEnabled ?? false
        self.integerPointsOnly = integerOnly
        self.onRegrade = onRegrade
        _draft = State(initialValue: SubmissionDraft.fromStoredSubmission(submission).normalized(integerPointsOnly: integerOnly))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Student") {
                    TextField("Student name", text: $draft.studentName)
                        .textInputAutocapitalization(.words)
                    Toggle("Name needs review", isOn: $draft.nameNeedsReview)

                    if draft.nameNeedsReview {
                        HighlightNotice(
                            message: "Name needs human review.",
                            color: .orange
                        )
                    }
                    if draft.validationNeedsReview {
                        HighlightNotice(
                            message: "Automated validation could not confirm this grading. Human review is recommended.",
                            color: .orange
                        )
                    }
                    LabeledContent("Saved", value: submission.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Score") {
                        ScorePairText(
                            awardedPoints: draft.totalScore,
                            maxPoints: draft.maxScore
                        )
                        .foregroundStyle(scoreForegroundColor(awardedPoints: draft.totalScore, maxPoints: draft.maxScore))
                    }
                }

                if !draft.pageData.isEmpty {
                    Section("Scanned Pages") {
                        ImageStripView(pageData: draft.pageData)
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
            .navigationTitle(draft.studentName.isEmpty ? "Saved Result" : draft.studentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        beginSave()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if let onRegrade {
                        Button("Regrade") {
                            onRegrade()
                        }
                    }
                }
            }
            .keyboardDismissToolbar()
        }
        .feedbackToast()
        .activityOverlay(isPresented: isSaving, text: "Saving submission...")
    }

    private func saveChanges() {
        let normalized = draft.normalized(integerPointsOnly: integerPointsOnly)
        submission.studentName = normalized.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.nameNeedsReview = normalized.nameNeedsReview
        submission.validationNeedsReview = false
        submission.overallNotes = normalized.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.teacherReviewed = true
        submission.processingStateRaw = StudentSubmissionProcessingState.completed.rawValue
        submission.processingDetail = nil
        submission.setQuestionGrades(normalized.grades)
        try? modelContext.save()
        feedbackCenter.show("Submission saved.")
        dismiss()
    }

    private func beginSave() {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            await Task.yield()
            saveChanges()
            isSaving = false
        }
    }
}

struct RubricQuestionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    let question: QuestionRubric
    @State private var displayLabel: String
    @State private var questionID: String
    @State private var promptText: String
    @State private var idealAnswer: String
    @State private var gradingCriteria: String
    @State private var maxPointsText: String
    @State private var isSaving = false

    init(question: QuestionRubric) {
        self.question = question
        _displayLabel = State(initialValue: question.displayLabel)
        _questionID = State(initialValue: question.questionID)
        _promptText = State(initialValue: question.promptText)
        _idealAnswer = State(initialValue: question.idealAnswer)
        _gradingCriteria = State(initialValue: question.gradingCriteria)
        _maxPointsText = State(initialValue: ScoreFormatting.scoreString(question.maxPoints))
    }

    var body: some View {
        Form {
            Section("Question") {
                TextField("Display label", text: $displayLabel)
                    .textInputAutocapitalization(.words)
                TextField("Question ID", text: $questionID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Max points", text: $maxPointsText)
                    .keyboardType((question.session?.integerPointsOnlyEnabled ?? false) ? .numberPad : .decimalPad)
            }

            Section("Prompt") {
                TextEditor(text: $promptText)
                    .frame(minHeight: 140)
                RenderedPreviewButton(title: "Prompt Preview", text: promptText)
            }

            Section("Ideal Answer") {
                TextEditor(text: $idealAnswer)
                    .frame(minHeight: 160)
                RenderedPreviewButton(title: "Ideal Answer Preview", text: idealAnswer)
            }

            Section("Grading Criteria") {
                TextEditor(text: $gradingCriteria)
                    .frame(minHeight: 160)
                RenderedPreviewButton(title: "Grading Criteria Preview", text: gradingCriteria)
            }
        }
        .navigationTitle(displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Question" : displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    beginSave()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!canSave || !hasUnsavedChanges || isSaving)
            }
        }
        .onDisappear {
            scheduleAutosaveIfNeeded()
        }
        .keyboardDismissToolbar()
        .feedbackToast()
        .activityOverlay(isPresented: isSaving, text: "Saving question...")
    }

    private var canSave: Bool {
        !displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !questionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        PointPolicy.parse(maxPointsText, integerOnly: question.session?.integerPointsOnlyEnabled ?? false) != nil
    }

    private var hasUnsavedChanges: Bool {
        displayLabel != question.displayLabel ||
        questionID != question.questionID ||
        promptText != question.promptText ||
        idealAnswer != question.idealAnswer ||
        gradingCriteria != question.gradingCriteria ||
        maxPointsText != ScoreFormatting.scoreString(question.maxPoints)
    }

    private func persistChanges(showFeedback: Bool) {
        guard canSave else { return }

        question.displayLabel = displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        question.questionID = questionID.trimmingCharacters(in: .whitespacesAndNewlines)
        question.promptText = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        question.idealAnswer = idealAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        question.gradingCriteria = gradingCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
        question.maxPoints = PointPolicy.parse(
            maxPointsText,
            integerOnly: question.session?.integerPointsOnlyEnabled ?? false
        ) ?? question.maxPoints
        try? modelContext.save()

        if showFeedback {
            feedbackCenter.show("Question saved.")
        }
    }

    private func beginSave() {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            await Task.yield()
            persistChanges(showFeedback: true)
            isSaving = false
        }
    }

    private func scheduleAutosaveIfNeeded() {
        guard hasUnsavedChanges, !isSaving else { return }
        Task { @MainActor in
            await Task.yield()
            guard hasUnsavedChanges, !isSaving else { return }
            persistChanges(showFeedback: false)
        }
    }
}

struct OverallRulesEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    let session: GradingSession
    @State private var rulesText: String
    @State private var isSaving = false

    init(session: GradingSession) {
        self.session = session
        _rulesText = State(initialValue: session.overallGradingRules ?? "")
    }

    var body: some View {
        Form {
            Section("Overall Grading Rules") {
                TextEditor(text: $rulesText)
                .frame(minHeight: 180)

                RenderedPreviewButton(title: "Overall Rules Preview", text: rulesText)
            }
        }
        .navigationTitle("Overall Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    beginSave()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!hasUnsavedChanges || isSaving)
            }
        }
        .onDisappear {
            scheduleAutosaveIfNeeded()
        }
        .keyboardDismissToolbar()
        .feedbackToast()
        .activityOverlay(isPresented: isSaving, text: "Saving rules...")
    }

    private var hasUnsavedChanges: Bool {
        rulesText != (session.overallGradingRules ?? "")
    }

    private func persistChanges(showFeedback: Bool) {
        let trimmed = rulesText.trimmingCharacters(in: .whitespacesAndNewlines)
        session.overallGradingRules = trimmed.isEmpty ? nil : rulesText
        try? modelContext.save()

        if showFeedback {
            feedbackCenter.show("Overall rules saved.")
        }
    }

    private func beginSave() {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            await Task.yield()
            persistChanges(showFeedback: true)
            isSaving = false
        }
    }

    private func scheduleAutosaveIfNeeded() {
        guard hasUnsavedChanges, !isSaving else { return }
        Task { @MainActor in
            await Task.yield()
            guard hasUnsavedChanges, !isSaving else { return }
            persistChanges(showFeedback: false)
        }
    }
}
