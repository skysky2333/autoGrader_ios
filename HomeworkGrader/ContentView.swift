import SwiftUI
import SwiftData
import VisionKit

struct ContentView: View {
    @Query(sort: \GradingSession.createdAt, order: .reverse) private var sessions: [GradingSession]
    @State private var showingNewSession = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Grading Sessions", systemImage: "doc.text.viewfinder")
                    } description: {
                        Text("Create a session, scan the blank assignment, approve the rubric, and then grade students one by one.")
                    } actions: {
                        Button("New Session") {
                            showingNewSession = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if !hasAPIKey {
                            Section {
                                Label("Add your OpenAI API key in Settings before scanning or grading.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }

                        ForEach(sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                SessionRow(session: session)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Homework Grader")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings") {
                        showingSettings = true
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewSession = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private var hasAPIKey: Bool {
        let key = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct SessionRow: View {
    let session: GradingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.title)
                    .font(.headline)
                if session.isFinished {
                    StatusChip(label: "Ended", color: .gray)
                } else if session.questions.isEmpty {
                    StatusChip(label: "Needs Rubric", color: .orange)
                } else {
                    StatusChip(label: "Ready", color: .green)
                }
            }

            Text("Created \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\(session.sortedQuestions.count) questions • \(session.sortedSubmissions.count) submissions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title = ""
    @State private var answerModel = ModelCatalog.defaultAnswerModel
    @State private var gradingModel = ModelCatalog.defaultGradingModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Assignment title", text: $title)
                        .textInputAutocapitalization(.words)
                    Text("Create the session first, then scan the blank assignment to generate the rubric.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("OpenAI Models") {
                    ModelTextField(title: "Answer generation model", text: $answerModel)
                    ModelTextField(title: "Grading model", text: $gradingModel)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createSession()
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !answerModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gradingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createSession() {
        let session = GradingSession(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            answerModelID: answerModel.trimmingCharacters(in: .whitespacesAndNewlines),
            gradingModelID: gradingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(session)
        try? modelContext.save()
        dismiss()
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
    @State private var statusMessage = ""
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI API Key") {
                    SecureField("sk-...", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("This private prototype stores the key in the device Keychain. Do not use this architecture for a public app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(statusMessage.contains("works") ? .green : .secondary)
                    }
                }

                Section("Actions") {
                    Button("Save Key") {
                        saveKey()
                    }

                    Button(isTesting ? "Testing..." : "Test Key") {
                        Task {
                            await testKey()
                        }
                    }
                    .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Clear Key", role: .destructive) {
                        apiKey = ""
                        KeychainStore.shared.deleteValue(for: AppSecrets.openAIKey)
                        statusMessage = "API key removed."
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.shared.setString(trimmed, for: AppSecrets.openAIKey)
        statusMessage = trimmed.isEmpty ? "API key cleared." : "API key saved."
    }

    @MainActor
    private func testKey() async {
        isTesting = true
        defer { isTesting = false }

        do {
            try await OpenAIService.shared.validateAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            statusMessage = "API key works."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct SessionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var session: GradingSession

    @State private var showingMasterScanner = false
    @State private var showingStudentScanner = false
    @State private var rubricReviewState: RubricReviewState?
    @State private var submissionDraft: SubmissionDraft?
    @State private var selectedSubmission: StudentSubmission?
    @State private var shareItem: ShareItem?
    @State private var alertItem: AlertItem?
    @State private var busyMessage: String?

    var body: some View {
        Form {
            Section("Overview") {
                LabeledContent("Answer model", value: session.answerModelID)
                LabeledContent("Grading model", value: session.gradingModelID)
                LabeledContent("Questions", value: "\(session.sortedQuestions.count)")
                LabeledContent("Saved submissions", value: "\(session.sortedSubmissions.count)")
                LabeledContent("Total points", value: ScoreFormatting.scoreString(session.totalPossiblePoints))

                Toggle("Session ended", isOn: $session.isFinished)
            }

            if session.questions.isEmpty {
                Section("Blank Assignment") {
                    Button {
                        startMasterScan()
                    } label: {
                        Label("Scan Blank Assignment", systemImage: "doc.viewfinder")
                    }
                    .disabled(!hasAPIKey)

                    Text(hasAPIKey ? "Scan the teacher copy or blank exam pages, then review the generated rubric before grading students." : "Add your API key in Settings first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Approved Rubric") {
                    if !session.masterScans().isEmpty {
                        ImageStripView(pageData: session.masterScans())
                    }

                    ForEach(session.sortedQuestions) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(question.displayLabel)
                                    .font(.headline)
                                Spacer()
                                Text("\(ScoreFormatting.scoreString(question.maxPoints)) pts")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Text(question.promptText)
                                .font(.subheadline)

                            Text(question.idealAnswer)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Grade Next Student") {
                    Button {
                        startStudentScan()
                    } label: {
                        Label("Scan Student Submission", systemImage: "camera.viewfinder")
                    }
                    .disabled(!hasAPIKey || session.isFinished)

                    Text(session.isFinished ? "This session is marked as ended. Turn off Session ended to grade more submissions." : "Capture all pages for one student, review the result, save it, and then scan the next student.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Saved Results") {
                    if session.sortedSubmissions.isEmpty {
                        Text("No student submissions saved yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(session.sortedSubmissions) { submission in
                            Button {
                                selectedSubmission = submission
                            } label: {
                                SubmissionRow(submission: submission)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Export") {
                    Button {
                        exportCSV()
                    } label: {
                        Label("Export Session CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(session.sortedSubmissions.isEmpty)
                }
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingMasterScanner) {
            DocumentScannerView(
                onComplete: { images in
                    showingMasterScanner = false
                    Task {
                        await generateRubric(from: images)
                    }
                },
                onCancel: {
                    showingMasterScanner = false
                },
                onError: { error in
                    showingMasterScanner = false
                    alertItem = AlertItem(message: error.localizedDescription)
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingStudentScanner) {
            DocumentScannerView(
                onComplete: { images in
                    showingStudentScanner = false
                    Task {
                        await gradeSubmission(from: images)
                    }
                },
                onCancel: {
                    showingStudentScanner = false
                },
                onError: { error in
                    showingStudentScanner = false
                    alertItem = AlertItem(message: error.localizedDescription)
                }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $rubricReviewState) { reviewState in
            AnswerKeyReviewView(reviewState: reviewState) { approvedDrafts in
                saveRubric(approvedDrafts, pageData: reviewState.pageData)
                rubricReviewState = nil
            }
        }
        .sheet(item: $submissionDraft) { draft in
            SubmissionReviewView(draft: draft) { approvedDraft in
                saveSubmission(approvedDraft)
                submissionDraft = nil
            }
        }
        .sheet(item: $selectedSubmission) { submission in
            SavedSubmissionDetailView(submission: submission)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(item: $alertItem) { item in
            Alert(title: Text("Homework Grader"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .overlay {
            if let busyMessage {
                BusyOverlay(message: busyMessage)
            }
        }
    }

    private var hasAPIKey: Bool {
        let key = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startMasterScan() {
        guard VNDocumentCameraViewController.isSupported else {
            alertItem = AlertItem(message: "Document scanning is not available on this device.")
            return
        }

        showingMasterScanner = true
    }

    private func startStudentScan() {
        guard VNDocumentCameraViewController.isSupported else {
            alertItem = AlertItem(message: "Document scanning is not available on this device.")
            return
        }

        showingStudentScanner = true
    }

    @MainActor
    private func generateRubric(from images: [UIImage]) async {
        let pageData = images.compactMap { $0.jpegData(compressionQuality: 0.82) }
        guard !pageData.isEmpty else {
            alertItem = AlertItem(message: "The scan did not contain any pages.")
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        busyMessage = "Generating answer key..."
        defer { busyMessage = nil }

        do {
            let payload = try await OpenAIService.shared.generateAnswerKey(
                apiKey: apiKey,
                modelID: session.answerModelID,
                sessionTitle: session.title,
                pageData: pageData
            )

            guard !payload.questions.isEmpty else {
                alertItem = AlertItem(message: "The model did not return any gradeable questions. Try rescanning the blank assignment.")
                return
            }

            rubricReviewState = .from(payload: payload, pageData: pageData)
        } catch {
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    @MainActor
    private func gradeSubmission(from images: [UIImage]) async {
        let pageData = images.compactMap { $0.jpegData(compressionQuality: 0.82) }
        guard !pageData.isEmpty else {
            alertItem = AlertItem(message: "The scan did not contain any pages.")
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        busyMessage = "Grading submission..."
        defer { busyMessage = nil }

        do {
            let payload = try await OpenAIService.shared.gradeSubmission(
                apiKey: apiKey,
                modelID: session.gradingModelID,
                rubric: session.sortedQuestions.map(\.snapshot),
                pageData: pageData
            )

            submissionDraft = SubmissionDraft.from(payload: payload, rubric: session.sortedQuestions, pageData: pageData)
        } catch {
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    private func saveRubric(_ approvedDrafts: [RubricQuestionDraft], pageData: [Data]) {
        session.setMasterScans(pageData)

        for existing in session.questions {
            modelContext.delete(existing)
        }

        for (index, draft) in approvedDrafts.enumerated() {
            let question = QuestionRubric(
                orderIndex: index,
                questionID: draft.questionID.trimmingCharacters(in: .whitespacesAndNewlines),
                displayLabel: draft.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                promptText: draft.promptText.trimmingCharacters(in: .whitespacesAndNewlines),
                idealAnswer: draft.idealAnswer.trimmingCharacters(in: .whitespacesAndNewlines),
                gradingCriteria: draft.gradingCriteria.trimmingCharacters(in: .whitespacesAndNewlines),
                maxPoints: Double(draft.maxPointsText) ?? 0,
                session: session
            )
            modelContext.insert(question)
            session.questions.append(question)
        }

        session.rubricApprovedAt = .now
        try? modelContext.save()
    }

    private func saveSubmission(_ approvedDraft: SubmissionDraft) {
        let submission = StudentSubmission(
            studentName: approvedDraft.studentName.trimmingCharacters(in: .whitespacesAndNewlines),
            overallNotes: approvedDraft.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            teacherReviewed: true,
            totalScore: approvedDraft.totalScore,
            maxScore: approvedDraft.maxScore,
            session: session
        )
        submission.setScans(approvedDraft.pageData)
        submission.setQuestionGrades(approvedDraft.grades)
        modelContext.insert(submission)
        session.submissions.append(submission)
        try? modelContext.save()
    }

    private func exportCSV() {
        do {
            shareItem = ShareItem(url: try CSVExporter.temporaryFileURL(for: session))
        } catch {
            alertItem = AlertItem(message: "Unable to export CSV. \(error.localizedDescription)")
        }
    }
}

private struct AnswerKeyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var questionDrafts: [RubricQuestionDraft]
    let pageData: [Data]
    let onApprove: ([RubricQuestionDraft]) -> Void

    init(reviewState: RubricReviewState, onApprove: @escaping ([RubricQuestionDraft]) -> Void) {
        _questionDrafts = State(initialValue: reviewState.questionDrafts)
        self.pageData = reviewState.pageData
        self.onApprove = onApprove
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Scanned Pages") {
                    ImageStripView(pageData: pageData)
                    Text("Review and edit the generated answer key. Enter the max points for every question before approving.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ideal answer")
                                .font(.footnote.weight(.semibold))
                            TextEditor(text: $draft.idealAnswer)
                                .frame(minHeight: 120)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Grading criteria")
                                .font(.footnote.weight(.semibold))
                            TextEditor(text: $draft.gradingCriteria)
                                .frame(minHeight: 120)
                        }

                        TextField("Max points", text: $draft.maxPointsText)
                            .keyboardType(.decimalPad)
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
                    Button("Approve") {
                        onApprove(questionDrafts)
                    }
                    .disabled(!canApprove)
                }
            }
        }
    }

    private var canApprove: Bool {
        !questionDrafts.isEmpty &&
        questionDrafts.allSatisfy {
            !$0.questionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.idealAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.gradingCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (Double($0.maxPointsText) ?? 0) > 0
        }
    }
}

private struct SubmissionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SubmissionDraft
    let onSave: (SubmissionDraft) -> Void

    init(draft: SubmissionDraft, onSave: @escaping (SubmissionDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Student") {
                    TextField("Student name", text: $draft.studentName)
                        .textInputAutocapitalization(.words)

                    Text("The model extracts the name from the scanned pages. Correct it here before saving if needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if draft.requiresAttention {
                        Label("Teacher review is required before saving.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Scanned Pages") {
                    ImageStripView(pageData: draft.pageData)
                }

                Section("Scores") {
                    LabeledContent("Total", value: "\(ScoreFormatting.scoreString(draft.totalScore)) / \(ScoreFormatting.scoreString(draft.maxScore))")
                        .font(.headline)
                }

                ForEach($draft.grades) { $grade in
                    Section(grade.displayLabel) {
                        Stepper(value: $grade.awardedPoints, in: 0...grade.maxPoints, step: 0.5) {
                            LabeledContent("Awarded points", value: "\(ScoreFormatting.scoreString(grade.awardedPoints)) / \(ScoreFormatting.scoreString(grade.maxPoints))")
                        }

                        Toggle("Final answer correct", isOn: $grade.isAnswerCorrect)
                        Toggle("Work process correct", isOn: $grade.isProcessCorrect)
                        Toggle("Needs review", isOn: $grade.needsReview)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Feedback")
                                .font(.footnote.weight(.semibold))
                            TextEditor(text: $grade.feedback)
                                .frame(minHeight: 100)
                        }
                    }
                }

                Section("Overall Notes") {
                    TextEditor(text: $draft.overallNotes)
                        .frame(minHeight: 120)
                }
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
                    Button("Save") {
                        onSave(normalizedDraft)
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.grades.isEmpty
    }

    private var normalizedDraft: SubmissionDraft {
        var copy = draft
        copy.grades = copy.grades.map { grade in
            var adjusted = grade
            adjusted.awardedPoints = min(max(adjusted.awardedPoints, 0), adjusted.maxPoints)
            return adjusted
        }
        return copy
    }
}

private struct SavedSubmissionDetailView: View {
    let submission: StudentSubmission

    var body: some View {
        NavigationStack {
            Form {
                Section("Student") {
                    LabeledContent("Name", value: submission.studentName)
                    LabeledContent("Score", value: "\(ScoreFormatting.scoreString(submission.totalScore)) / \(ScoreFormatting.scoreString(submission.maxScore))")
                    LabeledContent("Saved", value: submission.createdAt.formatted(date: .abbreviated, time: .shortened))
                }

                if !submission.scans().isEmpty {
                    Section("Scanned Pages") {
                        ImageStripView(pageData: submission.scans())
                    }
                }

                Section("Per Question") {
                    ForEach(submission.questionGrades()) { grade in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(grade.displayLabel)
                                    .font(.headline)
                                Spacer()
                                Text("\(ScoreFormatting.scoreString(grade.awardedPoints)) / \(ScoreFormatting.scoreString(grade.maxPoints))")
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 8) {
                                StatusChip(label: grade.isAnswerCorrect ? "Answer OK" : "Answer Off", color: grade.isAnswerCorrect ? .green : .red)
                                StatusChip(label: grade.isProcessCorrect ? "Process OK" : "Process Off", color: grade.isProcessCorrect ? .green : .red)
                                if grade.needsReview {
                                    StatusChip(label: "Review", color: .orange)
                                }
                            }

                            Text(grade.feedback)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !submission.overallNotes.isEmpty {
                    Section("Overall Notes") {
                        Text(submission.overallNotes)
                    }
                }
            }
            .navigationTitle(submission.studentName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct SubmissionRow: View {
    let submission: StudentSubmission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(submission.studentName)
                    .font(.headline)
                Spacer()
                Text("\(ScoreFormatting.scoreString(submission.totalScore)) / \(ScoreFormatting.scoreString(submission.maxScore))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(submission.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            if submission.questionGrades().contains(where: \.needsReview) {
                StatusChip(label: "Review Needed", color: .orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ModelTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ModelCatalog.suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            text = suggestion
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
            }
        }
    }
}

private struct ImageStripView: View {
    let pageData: [Data]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(pageData.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 140, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            Text("Page \(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct StatusChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                Text(message)
                    .font(.headline)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct AlertItem: Identifiable {
    let id = UUID()
    let message: String
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
