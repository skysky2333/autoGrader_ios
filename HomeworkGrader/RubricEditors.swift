import SwiftUI
import SwiftData

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
