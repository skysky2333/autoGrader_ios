import SwiftUI
import SwiftData
import UIKit
import VisionKit
import WebKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
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
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteSession(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
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

    private func deleteSession(_ session: GradingSession) {
        modelContext.delete(session)
        try? modelContext.save()
    }
}

private enum SessionSectionTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case rubric = "Rubric"
    case results = "Results"

    var id: String { rawValue }
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

            Text("API cost: \(session.sessionCostLabel)")
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
    @State private var integerPointsOnly = true
    @State private var answerReasoningEffort: String? = nil
    @State private var gradingReasoningEffort: String? = nil
    @State private var answerVerbosity: String? = nil
    @State private var gradingVerbosity: String? = nil
    @State private var answerServiceTier: String? = nil
    @State private var gradingServiceTier: String? = nil

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

                Section("Scoring") {
                    Toggle("Integer points only", isOn: $integerPointsOnly)
                    Text("When enabled, rubric points and awarded scores are restricted to whole numbers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("Advanced API Settings") {
                        APIAdvancedSettingsEditor(
                            answerReasoningEffort: $answerReasoningEffort,
                            gradingReasoningEffort: $gradingReasoningEffort,
                            answerVerbosity: $answerVerbosity,
                            gradingVerbosity: $gradingVerbosity,
                            answerServiceTier: $answerServiceTier,
                            gradingServiceTier: $gradingServiceTier
                        )
                    }
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
            .keyboardDismissToolbar()
        }
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !answerModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gradingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createSession() {
        let currentKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        let session = GradingSession(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            answerModelID: answerModel.trimmingCharacters(in: .whitespacesAndNewlines),
            gradingModelID: gradingModel.trimmingCharacters(in: .whitespacesAndNewlines),
            answerReasoningEffort: answerReasoningEffort,
            gradingReasoningEffort: gradingReasoningEffort,
            answerVerbosity: answerVerbosity,
            gradingVerbosity: gradingVerbosity,
            answerServiceTier: answerServiceTier,
            gradingServiceTier: gradingServiceTier,
            apiKeyFingerprint: APIKeyIdentity.fingerprint(for: currentKey),
            integerPointsOnly: integerPointsOnly
        )
        modelContext.insert(session)
        try? modelContext.save()
        dismiss()
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \GradingSession.createdAt, order: .reverse) private var sessions: [GradingSession]
    @State private var apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
    @State private var statusMessage = ""
    @State private var isTesting = false
    @State private var costState: OrganizationCostState = .idle

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

                Section("API Cost") {
                    LabeledContent("Tracked in this app", value: CostFormatting.usdString(trackedAppCost))

                    switch costState {
                    case .idle:
                        Text("OpenAI organization cost has not been fetched yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .loading:
                        HStack {
                            ProgressView()
                            Text("Loading organization cost...")
                                .foregroundStyle(.secondary)
                        }
                    case .loaded(let summary):
                        LabeledContent("OpenAI organization total", value: CostFormatting.usdString(summary.totalCostUSD))
                        Text("Fetched \(summary.fetchedAt.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .unavailable(let message):
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button(costState == .loading ? "Refreshing..." : "Refresh OpenAI Cost") {
                        Task {
                            await refreshOrganizationCost()
                        }
                    }
                    .disabled(costState == .loading || trimmedAPIKey.isEmpty)

                    Text("The OpenAI organization cost endpoint may require an admin API key. The tracked in-app total is based on this app's own graded sessions for the current key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Actions") {
                    Button("Save Key") {
                        Task {
                            await saveKey()
                        }
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
            .task {
                if trimmedAPIKey.isEmpty { return }
                guard costState == .idle else { return }
                await refreshOrganizationCost()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .keyboardDismissToolbar()
        }
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trackedAppCost: Double {
        guard let fingerprint = APIKeyIdentity.fingerprint(for: trimmedAPIKey) else { return 0 }
        return sessions
            .filter { $0.apiKeyFingerprint == fingerprint }
            .reduce(0) { $0 + ($1.estimatedCostUSD ?? 0) }
    }

    @MainActor
    private func saveKey() async {
        KeychainStore.shared.setString(trimmedAPIKey, for: AppSecrets.openAIKey)
        statusMessage = trimmedAPIKey.isEmpty ? "API key cleared." : "API key saved."
        costState = .idle
        if !trimmedAPIKey.isEmpty {
            await refreshOrganizationCost()
        }
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

    @MainActor
    private func refreshOrganizationCost() async {
        guard !trimmedAPIKey.isEmpty else {
            costState = .idle
            return
        }

        costState = .loading

        do {
            let summary = try await OpenAIService.shared.fetchOrganizationTotalCost(apiKey: trimmedAPIKey)
            costState = .loaded(summary)
        } catch {
            costState = .unavailable(error.localizedDescription)
        }
    }
}

private struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var session: GradingSession

    @State private var showingMasterScanner = false
    @State private var showingStudentScanner = false
    @State private var selectedTab: SessionSectionTab = .overview
    @State private var resultsSearchText = ""
    @State private var rubricReviewState: RubricReviewState?
    @State private var submissionDraft: SubmissionDraft?
    @State private var selectedSubmission: StudentSubmission?
    @State private var shareItem: ShareItem?
    @State private var alertItem: AlertItem?
    @State private var busyMessage: String?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker("Section", selection: $selectedTab) {
                    ForEach(SessionSectionTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }

            if selectedTab == .overview {
                Section("Overview") {
                    LabeledContent("Answer model", value: session.answerModelID)
                    LabeledContent("Grading model", value: session.gradingModelID)
                    LabeledContent("Point mode", value: session.pointModeLabel)
                    LabeledContent("Questions", value: "\(session.sortedQuestions.count)")
                    LabeledContent("Saved submissions", value: "\(session.sortedSubmissions.count)")
                    LabeledContent("Total points", value: ScoreFormatting.scoreString(session.totalPossiblePoints))
                    LabeledContent("API cost", value: session.sessionCostLabel)

                    Toggle("Integer points only", isOn: integerPointsOnlyBinding)
                    Toggle("Session ended", isOn: $session.isFinished)
                }

                Section {
                    DisclosureGroup("Advanced API Settings") {
                        APIAdvancedSettingsEditor(
                            answerReasoningEffort: $session.answerReasoningEffort,
                            gradingReasoningEffort: $session.gradingReasoningEffort,
                            answerVerbosity: $session.answerVerbosity,
                            gradingVerbosity: $session.gradingVerbosity,
                            answerServiceTier: $session.answerServiceTier,
                            gradingServiceTier: $session.gradingServiceTier
                        )

                        LabeledContent("Answer reasoning", value: session.answerReasoningLabel)
                        LabeledContent("Grading reasoning", value: session.gradingReasoningLabel)
                        LabeledContent("Answer verbosity", value: session.answerVerbosityLabel)
                        LabeledContent("Grading verbosity", value: session.gradingVerbosityLabel)
                        LabeledContent("Answer tier", value: session.answerServiceTierLabel)
                        LabeledContent("Grading tier", value: session.gradingServiceTierLabel)
                    }
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
                }
            }

            if selectedTab == .rubric {
                if session.questions.isEmpty {
                    Section("Rubric") {
                        Text("No rubric yet. Scan the blank assignment from the Overview tab first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Master Pages") {
                        ImageStripView(pageData: session.masterScans())
                    }

                    Section("Questions") {
                        ForEach(session.sortedQuestions) { question in
                            NavigationLink {
                                RubricQuestionDetailView(question: question)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(question.displayLabel)
                                            .font(.headline)
                                        Text(question.promptText)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Text("\(ScoreFormatting.scoreString(question.maxPoints)) pts")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }

            if selectedTab == .results {
                Section("Search") {
                    TextField("Search by student name", text: $resultsSearchText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }

                Section("Saved Results") {
                    if filteredSubmissions.isEmpty {
                        Text("No student submissions saved yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredSubmissions) { submission in
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

                    Button {
                        exportPackage()
                    } label: {
                        Label("Export Full Session Package", systemImage: "archivebox")
                    }
                    .disabled(session.sortedSubmissions.isEmpty)
                }
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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
            AnswerKeyReviewView(reviewState: reviewState, integerPointsOnly: session.integerPointsOnlyEnabled) { approvedDrafts in
                saveRubric(approvedDrafts, pageData: reviewState.pageData)
                rubricReviewState = nil
            }
        }
        .sheet(item: $submissionDraft) { draft in
            SubmissionReviewView(
                draft: draft,
                integerPointsOnly: session.integerPointsOnlyEnabled,
                onSave: { approvedDraft in
                    saveSubmission(approvedDraft)
                    submissionDraft = nil
                },
                onSaveAndScanNext: { approvedDraft in
                    saveSubmission(approvedDraft)
                    submissionDraft = nil
                    startStudentScan()
                }
            )
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
        .confirmationDialog("Delete this session?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) {
                deleteSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the rubric, scans, and saved results for this session.")
        }
        .overlay {
            if let busyMessage {
                BusyOverlay(message: busyMessage)
            }
        }
        .keyboardDismissToolbar()
    }

    private var hasAPIKey: Bool {
        let key = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var integerPointsOnlyBinding: Binding<Bool> {
        Binding(
            get: { session.integerPointsOnlyEnabled },
            set: { newValue in
                session.integerPointsOnly = newValue
                if newValue {
                    normalizeSessionToIntegerPoints()
                }
                try? modelContext.save()
            }
        )
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
            let result = try await OpenAIService.shared.generateAnswerKey(
                apiKey: apiKey,
                modelID: session.answerModelID,
                sessionTitle: session.title,
                pageData: pageData,
                reasoningEffort: session.answerReasoningEffort,
                verbosity: session.answerVerbosity,
                serviceTier: session.answerServiceTier
            )

            recordUsage(result.usage, apiKey: apiKey)

            guard !result.payload.questions.isEmpty else {
                alertItem = AlertItem(message: "The model did not return any gradeable questions. Try rescanning the blank assignment.")
                return
            }

            rubricReviewState = .from(payload: result.payload, pageData: pageData, integerPointsOnly: session.integerPointsOnlyEnabled)
                .normalized(integerPointsOnly: session.integerPointsOnlyEnabled)
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
            let result = try await OpenAIService.shared.gradeSubmission(
                apiKey: apiKey,
                modelID: session.gradingModelID,
                rubric: session.sortedQuestions.map(\.snapshot),
                pageData: pageData,
                integerPointsOnly: session.integerPointsOnlyEnabled,
                reasoningEffort: session.gradingReasoningEffort,
                verbosity: session.gradingVerbosity,
                serviceTier: session.gradingServiceTier
            )

            recordUsage(result.usage, apiKey: apiKey)

            submissionDraft = SubmissionDraft.from(
                payload: result.payload,
                rubric: session.sortedQuestions,
                pageData: pageData,
                integerPointsOnly: session.integerPointsOnlyEnabled
            )
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
                maxPoints: PointPolicy.parse(draft.maxPointsText, integerOnly: session.integerPointsOnlyEnabled) ?? 0,
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

    private func exportPackage() {
        do {
            shareItem = ShareItem(url: try SessionExporter.temporaryPackageURL(for: session))
        } catch {
            alertItem = AlertItem(message: "Unable to export the full session package. \(error.localizedDescription)")
        }
    }

    private func recordUsage(_ usage: OpenAIUsageSummary?, apiKey: String) {
        guard let usage else { return }

        session.estimatedCostUSD = (session.estimatedCostUSD ?? 0) + usage.estimatedCostUSD
        if session.apiKeyFingerprint == nil {
            session.apiKeyFingerprint = APIKeyIdentity.fingerprint(for: apiKey)
        }
        try? modelContext.save()
    }

    private func normalizeSessionToIntegerPoints() {
        for question in session.questions {
            question.maxPoints = PointPolicy.normalize(question.maxPoints, integerOnly: true)
        }

        for submission in session.submissions {
            let normalizedGrades = submission.questionGrades().map { grade in
                var adjusted = grade
                adjusted.maxPoints = PointPolicy.normalize(adjusted.maxPoints, integerOnly: true)
                adjusted.awardedPoints = PointPolicy.normalize(adjusted.awardedPoints, maxPoints: adjusted.maxPoints, integerOnly: true)
                return adjusted
            }
            submission.setQuestionGrades(normalizedGrades)
        }
    }

    private func deleteSession() {
        modelContext.delete(session)
        try? modelContext.save()
        dismiss()
    }

    private var filteredSubmissions: [StudentSubmission] {
        let trimmed = resultsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return session.sortedSubmissions }
        return session.sortedSubmissions.filter {
            $0.studentName.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

private struct AnswerKeyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var questionDrafts: [RubricQuestionDraft]
    @State private var defaultPointsText = "1"
    let pageData: [Data]
    let integerPointsOnly: Bool
    let onApprove: ([RubricQuestionDraft]) -> Void

    init(reviewState: RubricReviewState, integerPointsOnly: Bool, onApprove: @escaping ([RubricQuestionDraft]) -> Void) {
        _questionDrafts = State(initialValue: reviewState.questionDrafts)
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
                            RenderedTextBlock(text: draft.promptText)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ideal answer")
                                .font(.footnote.weight(.semibold))
                            TextEditor(text: $draft.idealAnswer)
                                .frame(minHeight: 120)
                            RenderedTextBlock(text: draft.idealAnswer)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Grading criteria")
                                .font(.footnote.weight(.semibold))
                            TextEditor(text: $draft.gradingCriteria)
                                .frame(minHeight: 120)
                            RenderedTextBlock(text: draft.gradingCriteria)
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
                    Button("Approve") {
                        onApprove(questionDrafts)
                    }
                    .disabled(!canApprove)
                }
            }
            .keyboardDismissToolbar()
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
    }
}

private struct SubmissionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SubmissionDraft
    let integerPointsOnly: Bool
    let onSave: (SubmissionDraft) -> Void
    let onSaveAndScanNext: (SubmissionDraft) -> Void

    init(
        draft: SubmissionDraft,
        integerPointsOnly: Bool,
        onSave: @escaping (SubmissionDraft) -> Void,
        onSaveAndScanNext: @escaping (SubmissionDraft) -> Void
    ) {
        _draft = State(initialValue: draft.normalized(integerPointsOnly: integerPointsOnly))
        self.integerPointsOnly = integerPointsOnly
        self.onSave = onSave
        self.onSaveAndScanNext = onSaveAndScanNext
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
                    if integerPointsOnly {
                        Text("Integer-points mode is on. Awarded scores are restricted to whole numbers.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach($draft.grades) { $grade in
                    Section(grade.displayLabel) {
                        Stepper(value: $grade.awardedPoints, in: 0...grade.maxPoints, step: PointPolicy.step(integerOnly: integerPointsOnly)) {
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
                            RenderedTextBlock(text: grade.feedback)
                        }
                    }
                }

                Section("Overall Notes") {
                    TextEditor(text: $draft.overallNotes)
                        .frame(minHeight: 120)
                    RenderedTextBlock(text: draft.overallNotes)
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

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save & Scan Next") {
                        onSaveAndScanNext(normalizedDraft)
                    }
                    .disabled(!canSave)
                }
            }
            .keyboardDismissToolbar()
        }
    }

    private var canSave: Bool {
        !draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.grades.isEmpty
    }

    private var normalizedDraft: SubmissionDraft {
        draft.normalized(integerPointsOnly: integerPointsOnly)
    }
}

private struct SavedSubmissionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let submission: StudentSubmission
    let integerPointsOnly: Bool
    @State private var draft: SubmissionDraft

    init(submission: StudentSubmission) {
        self.submission = submission
        let integerOnly = submission.session?.integerPointsOnlyEnabled ?? false
        self.integerPointsOnly = integerOnly
        _draft = State(initialValue: SubmissionDraft.fromStoredSubmission(submission).normalized(integerPointsOnly: integerOnly))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Student") {
                    TextField("Student name", text: $draft.studentName)
                        .textInputAutocapitalization(.words)
                    LabeledContent("Saved", value: submission.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Score", value: "\(ScoreFormatting.scoreString(draft.totalScore)) / \(ScoreFormatting.scoreString(draft.maxScore))")
                }

                if !draft.pageData.isEmpty {
                    Section("Scanned Pages") {
                        ImageStripView(pageData: draft.pageData)
                    }
                }

                ForEach($draft.grades) { $grade in
                    Section(grade.displayLabel) {
                        Stepper(value: $grade.awardedPoints, in: 0...grade.maxPoints, step: PointPolicy.step(integerOnly: integerPointsOnly)) {
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
                            RenderedTextBlock(text: grade.feedback)
                        }
                    }
                }

                Section("Overall Notes") {
                    TextEditor(text: $draft.overallNotes)
                        .frame(minHeight: 120)
                    RenderedTextBlock(text: draft.overallNotes)
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
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .keyboardDismissToolbar()
        }
    }

    private func saveChanges() {
        let normalized = draft.normalized(integerPointsOnly: integerPointsOnly)
        submission.studentName = normalized.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.overallNotes = normalized.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.teacherReviewed = true
        submission.setQuestionGrades(normalized.grades)
        try? modelContext.save()
        dismiss()
    }
}

private struct RubricQuestionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var question: QuestionRubric
    @State private var maxPointsText: String

    init(question: QuestionRubric) {
        self.question = question
        _maxPointsText = State(initialValue: ScoreFormatting.scoreString(question.maxPoints))
    }

    var body: some View {
        Form {
            Section("Question") {
                TextField("Display label", text: $question.displayLabel)
                    .textInputAutocapitalization(.words)
                TextField("Question ID", text: $question.questionID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Max points", text: $maxPointsText)
                    .keyboardType((question.session?.integerPointsOnlyEnabled ?? false) ? .numberPad : .decimalPad)
                    .onChange(of: maxPointsText) { _, newValue in
                        if let parsed = PointPolicy.parse(newValue, integerOnly: question.session?.integerPointsOnlyEnabled ?? false) {
                            question.maxPoints = parsed
                            try? modelContext.save()
                        }
                    }
            }

            Section("Prompt") {
                TextEditor(text: $question.promptText)
                    .frame(minHeight: 140)
                RenderedTextBlock(text: question.promptText)
            }

            Section("Ideal Answer") {
                TextEditor(text: $question.idealAnswer)
                    .frame(minHeight: 160)
                RenderedTextBlock(text: question.idealAnswer)
            }

            Section("Grading Criteria") {
                TextEditor(text: $question.gradingCriteria)
                    .frame(minHeight: 160)
                RenderedTextBlock(text: question.gradingCriteria)
            }
        }
        .navigationTitle(question.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            try? modelContext.save()
        }
        .keyboardDismissToolbar()
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

private struct APIAdvancedSettingsEditor: View {
    @Binding var answerReasoningEffort: String?
    @Binding var gradingReasoningEffort: String?
    @Binding var answerVerbosity: String?
    @Binding var gradingVerbosity: String?
    @Binding var answerServiceTier: String?
    @Binding var gradingServiceTier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdvancedSettingPicker(
                title: "Answer reasoning effort",
                selection: $answerReasoningEffort,
                options: APIRequestTuningCatalog.reasoningEffortOptions
            )
            AdvancedSettingPicker(
                title: "Grading reasoning effort",
                selection: $gradingReasoningEffort,
                options: APIRequestTuningCatalog.reasoningEffortOptions
            )
            AdvancedSettingPicker(
                title: "Answer verbosity",
                selection: $answerVerbosity,
                options: APIRequestTuningCatalog.verbosityOptions
            )
            AdvancedSettingPicker(
                title: "Grading verbosity",
                selection: $gradingVerbosity,
                options: APIRequestTuningCatalog.verbosityOptions
            )
            AdvancedSettingPicker(
                title: "Answer service tier",
                selection: $answerServiceTier,
                options: APIRequestTuningCatalog.serviceTierOptions
            )
            AdvancedSettingPicker(
                title: "Grading service tier",
                selection: $gradingServiceTier,
                options: APIRequestTuningCatalog.serviceTierOptions
            )
        }
        .padding(.top, 8)
    }
}

private struct AdvancedSettingPicker: View {
    let title: String
    @Binding var selection: String?
    let options: [APIRequestTuningOption]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.menu)
    }
}

private struct DetailCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct ImageStripView: View {
    let pageData: [Data]
    @State private var selectedImage: ZoomableImageItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(pageData.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Button {
                            selectedImage = ZoomableImageItem(image: image, title: "Page \(index + 1)")
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color(.secondarySystemBackground))

                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .padding(8)
                                }
                                .frame(width: 150, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                }
                                Text("Page \(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .fullScreenCover(item: $selectedImage) { item in
            FullScreenImageViewer(item: item)
        }
    }
}

private struct RenderedTextBlock: View {
    let text: String
    @State private var contentHeight: CGFloat = 44

    var body: some View {
        MathRenderedTextView(text: text, contentHeight: $contentHeight)
            .frame(minHeight: max(contentHeight, 44), maxHeight: max(contentHeight, 44))
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white)
            )
    }
}

private struct MathRenderedTextView: UIViewRepresentable {
    let text: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "contentHeight")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = htmlDocument(for: text)
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "contentHeight")
    }

    private func htmlDocument(for text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br/>")

        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
          <style>
            body {
              margin: 0;
              padding: 0;
              background: transparent;
              color: #111827;
              font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
              font-size: 17px;
              line-height: 1.45;
              overflow-wrap: break-word;
            }
            .wrap {
              width: 100%;
              background: transparent;
            }
            p { margin: 0 0 0.9em 0; }
            mjx-container { margin: 0.35em 0 !important; }
          </style>
          <script>
            window.MathJax = {
              tex: {
                inlineMath: [['$', '$'], ['\\\\(', '\\\\)']],
                displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']]
              },
              svg: { fontCache: 'global' }
            };

            function reportHeight() {
              const height = Math.max(
                document.body.scrollHeight,
                document.documentElement.scrollHeight
              );
              window.webkit.messageHandlers.contentHeight.postMessage(height);
            }

            function waitForMathJax(retries) {
              if (window.MathJax && window.MathJax.typesetPromise) {
                MathJax.typesetPromise().then(function() {
                  setTimeout(reportHeight, 60);
                }).catch(function() {
                  setTimeout(reportHeight, 60);
                });
                return;
              }

              if (retries > 0) {
                setTimeout(function() {
                  waitForMathJax(retries - 1);
                }, 75);
              } else {
                setTimeout(reportHeight, 60);
              }
            }

            window.addEventListener('load', function() {
              waitForMathJax(80);
            });
          </script>
          <script async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js"></script>
        </head>
        <body>
          <div class="wrap">\(escaped)</div>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var contentHeight: CGFloat
        var lastHTML = ""

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "contentHeight" else { return }

            if let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    self.contentHeight = max(height, 44)
                }
            } else if let height = message.body as? Double {
                DispatchQueue.main.async {
                    self.contentHeight = max(height, 44)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("reportHeight();", completionHandler: nil)
        }
    }
}

private struct ZoomableImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String
}

private struct FullScreenImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let item: ZoomableImageItem

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ZoomableImageScrollView(image: item.image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding()
            }
        }
        .overlay(alignment: .topLeading) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .padding()
        }
        .statusBarHidden()
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 6
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.imageView.frame = uiView.bounds
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()

        init(image: UIImage) {
            super.init()
            imageView.image = image
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
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

private enum OrganizationCostState: Equatable {
    case idle
    case loading
    case loaded(OrganizationCostSummary)
    case unavailable(String)
}

private struct KeyboardDismissToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

private extension View {
    func keyboardDismissToolbar() -> some View {
        modifier(KeyboardDismissToolbarModifier())
    }
}
