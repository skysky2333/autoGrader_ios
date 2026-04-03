import SwiftUI
import SwiftData

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
        .feedbackToast()
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
                } else if session.submissions.contains(where: \.isProcessingPending) {
                    StatusChip(label: "Batch Pending", color: .orange)
                } else {
                    StatusChip(label: "Ready", color: .green)
                }
            }

            Text("Created \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\(session.questions.count) questions • \(session.submissions.count) submissions")
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
    @EnvironmentObject private var feedbackCenter: FeedbackCenter

    @State private var title = ""
    @State private var answerModel = ModelCatalog.defaultAnswerModel
    @State private var gradingModel = ModelCatalog.defaultGradingModel
    @State private var validationEnabled = true
    @State private var validationModel = ModelCatalog.defaultValidationModel
    @State private var integerPointsOnly = true
    @State private var relaxedGradingMode = false
    @State private var answerReasoningEffort: String? = "high"
    @State private var gradingReasoningEffort: String? = "high"
    @State private var validationReasoningEffort: String? = "high"
    @State private var answerVerbosity: String? = nil
    @State private var gradingVerbosity: String? = nil
    @State private var validationVerbosity: String? = nil
    @State private var answerServiceTier: String? = "flex"
    @State private var gradingServiceTier: String? = "flex"
    @State private var validationServiceTier: String? = "flex"

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
                    Toggle("Enable validation model", isOn: $validationEnabled)
                    if validationEnabled {
                        ModelTextField(title: "Validation model", text: $validationModel)
                    }
                }

                Section("Scoring") {
                    Toggle("Integer points only", isOn: $integerPointsOnly)
                    Toggle("Relaxed grading mode", isOn: $relaxedGradingMode)
                    Text("When enabled, rubric points and awarded scores are restricted to whole numbers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Relaxed grading mode gives full credit whenever the final answer is correct, even if the work process is imperfect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("Advanced API Settings") {
                        APIAdvancedSettingsEditor(
                            validationEnabled: $validationEnabled,
                            answerReasoningEffort: $answerReasoningEffort,
                            gradingReasoningEffort: $gradingReasoningEffort,
                            validationReasoningEffort: $validationReasoningEffort,
                            answerVerbosity: $answerVerbosity,
                            gradingVerbosity: $gradingVerbosity,
                            validationVerbosity: $validationVerbosity,
                            answerServiceTier: $answerServiceTier,
                            gradingServiceTier: $gradingServiceTier,
                            validationServiceTier: $validationServiceTier
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
        .feedbackToast()
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
            validationModelID: validationEnabled ? validationModel.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            validationEnabled: validationEnabled,
            answerReasoningEffort: answerReasoningEffort,
            gradingReasoningEffort: gradingReasoningEffort,
            validationReasoningEffort: validationReasoningEffort,
            answerVerbosity: answerVerbosity,
            gradingVerbosity: gradingVerbosity,
            validationVerbosity: validationVerbosity,
            answerServiceTier: answerServiceTier,
            gradingServiceTier: gradingServiceTier,
            validationServiceTier: validationServiceTier,
            relaxedGradingMode: relaxedGradingMode,
            apiKeyFingerprint: APIKeyIdentity.fingerprint(for: currentKey),
            integerPointsOnly: integerPointsOnly
        )
        modelContext.insert(session)
        try? modelContext.save()
        feedbackCenter.show("Session created.")
        dismiss()
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
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
        .feedbackToast()
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
        feedbackCenter.show(statusMessage)
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
            feedbackCenter.show(statusMessage)
        } catch {
            statusMessage = error.localizedDescription
            feedbackCenter.show(statusMessage, tone: .error)
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
