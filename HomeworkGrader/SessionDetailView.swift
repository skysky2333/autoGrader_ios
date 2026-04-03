import SwiftUI
import SwiftData
import UIKit
import VisionKit

private enum ScanImagePreparation {
    static func makeJPEGPageData(from images: [UIImage]) async -> [Data] {
        await Task.detached(priority: .userInitiated) {
            images.compactMap { image in
                autoreleasepool {
                    originalResolutionJPEGData(from: image)
                }
            }
        }.value
    }

    private static func originalResolutionJPEGData(from image: UIImage) -> Data? {
        let normalized = normalizedImage(from: image)
        return normalized.jpegData(compressionQuality: 1.0)
    }

    private static func normalizedImage(from image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

private enum SessionSectionTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case rubric = "Rubric"
    case results = "Results"

    var id: String { rawValue }
}

private enum ScanIntent: Equatable {
    case master
    case student
    case batch
}

private struct ActiveCaptureFlow: Identifiable, Equatable {
    let kind: ScanIntent
    let source: ScanCaptureSource

    var id: String {
        "\(source.rawValue)-\(String(describing: kind))"
    }
}

@MainActor
struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var session: GradingSession

    @State private var showingScanSourcePicker = false
    @State private var showingBatchScanSetup = false
    @State private var pendingScanIntent: ScanIntent?
    @State private var pendingScanSource: ScanCaptureSource?
    @State private var activeCaptureFlow: ActiveCaptureFlow?
    @State private var queuedCaptureFlow: ActiveCaptureFlow?
    @State private var selectedTab: SessionSectionTab = .overview
    @State private var resultsSearchText = ""
    @State private var rubricReviewState: RubricReviewState?
    @State private var submissionDraft: SubmissionDraft?
    @State private var selectedSubmission: StudentSubmission?
    @State private var shareItem: ShareItem?
    @State private var alertItem: AlertItem?
    @State private var busyState: BusyOverlayState?
    @State private var preparingState: BusyOverlayState?
    @State private var showingDeleteConfirmation = false
    @State private var pendingBatchPagesPerSubmission: Int?
    @State private var isEditingOverviewConfig = false
    @State private var draftAnswerModelID = ""
    @State private var draftGradingModelID = ""
    @State private var draftValidationModelID = ""
    @State private var draftValidationEnabled = true
    @State private var draftIntegerPointsOnly = false
    @State private var draftRelaxedGradingMode = false
    @State private var draftSessionEnded = false
    @State private var draftAnswerReasoningEffort: String? = nil
    @State private var draftGradingReasoningEffort: String? = nil
    @State private var draftValidationReasoningEffort: String? = nil
    @State private var draftAnswerVerbosity: String? = nil
    @State private var draftGradingVerbosity: String? = nil
    @State private var draftValidationVerbosity: String? = nil
    @State private var draftAnswerServiceTier: String? = nil
    @State private var draftGradingServiceTier: String? = nil
    @State private var draftValidationServiceTier: String? = nil
    @State private var isRefreshingPendingBatches = false
    @State private var lastPendingBatchRefreshAt: Date?

    var body: some View {
        Form {
            tabPickerSection
            tabContentSections
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
        .confirmationDialog("Choose Scan Source", isPresented: $showingScanSourcePicker, titleVisibility: .visible) {
            Button {
                selectScanSource(.documentScanner)
            } label: {
                Label(ScanCaptureSource.documentScanner.buttonTitle, systemImage: ScanCaptureSource.documentScanner.systemImage)
            }

            Button {
                selectScanSource(.camera)
            } label: {
                Label(ScanCaptureSource.camera.buttonTitle, systemImage: ScanCaptureSource.camera.systemImage)
            }

            Button("Cancel", role: .cancel) {
                pendingScanIntent = nil
                pendingScanSource = nil
            }
        } message: {
            Text("Document Scanner auto-detects pages. Camera mode lets you keep taking photos and works for batch capture too.")
        }
        .sheet(isPresented: $showingBatchScanSetup, onDismiss: {
            if let queuedCaptureFlow {
                activeCaptureFlow = queuedCaptureFlow
                self.queuedCaptureFlow = nil
            }
            if pendingBatchPagesPerSubmission == nil {
                pendingScanIntent = nil
                pendingScanSource = nil
            }
        }) {
            BatchScanSetupView(initialPagesPerSubmission: session.maxPagesPerSubmission ?? 1) { pagesPerSubmission in
                pendingBatchPagesPerSubmission = pagesPerSubmission
                session.maxPagesPerSubmission = pagesPerSubmission
                try? modelContext.save()
                showPreparingOverlay(title: "Preparing \(pendingScanSource?.buttonTitle ?? ScanCaptureSource.documentScanner.buttonTitle)")
                queuedCaptureFlow = ActiveCaptureFlow(kind: .batch, source: pendingScanSource ?? .documentScanner)
                showingBatchScanSetup = false
            }
        }
        .sheet(item: $activeCaptureFlow) { flow in
            switch flow.source {
            case .documentScanner:
                DocumentScannerView(
                    onComplete: { images in
                        handleCaptureCompletion(images, for: flow)
                    },
                    onCancel: {
                        handleCaptureCancellation(for: flow)
                    },
                    onError: { error in
                        handleCaptureError(error, for: flow)
                    }
                )
                .ignoresSafeArea()
            case .camera:
                CameraCaptureView(
                    onComplete: { images in
                        handleCaptureCompletion(images, for: flow)
                    },
                    onCancel: {
                        handleCaptureCancellation(for: flow)
                    },
                    onError: { error in
                        handleCaptureError(error, for: flow)
                    }
                )
                .ignoresSafeArea()
            }
        }
        .sheet(item: $rubricReviewState) { reviewState in
            AnswerKeyReviewView(reviewState: reviewState, integerPointsOnly: session.integerPointsOnlyEnabled) { overallRules, approvedDrafts in
                saveRubric(overallRules: overallRules, approvedDrafts: approvedDrafts, pageData: reviewState.pageData)
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
        .onChange(of: showingScanSourcePicker) { _, newValue in
            if newValue {
                clearPreparingOverlay()
            }
        }
        .onChange(of: showingBatchScanSetup) { _, newValue in
            if newValue {
                clearPreparingOverlay()
            }
        }
        .onChange(of: activeCaptureFlow) { _, newValue in
            if newValue != nil {
                clearPreparingOverlay()
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            guard newValue == .results else { return }
            Task {
                await refreshPendingBatchSubmissions(force: false)
            }
        }
        .task {
            await refreshPendingBatchSubmissions(force: false)
        }
        .overlay {
            if let overlayState = busyState ?? preparingState {
                BusyOverlay(state: overlayState)
            }
        }
        .keyboardDismissToolbar()
    }

    private var tabPickerSection: some View {
        Section {
            Picker("Section", selection: $selectedTab) {
                ForEach(SessionSectionTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var tabContentSections: some View {
        switch selectedTab {
        case .overview:
            overviewSections
        case .rubric:
            rubricSections
        case .results:
            resultsSections
        }
    }

    @ViewBuilder
    private var overviewSections: some View {
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

                Button {
                    startBatchStudentScan()
                } label: {
                    Label("Batch Scan Submissions", systemImage: "square.stack.3d.down.right")
                }
                .disabled(!hasAPIKey || session.isFinished)

                if session.isFinished {
                    Text("This session is marked as ended. Turn off Session ended to grade more submissions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Single scan captures one student at a time, then opens the review screen before saving.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Batch scan asks for pages per submission, uploads one asynchronous OpenAI batch job, and returns you to the app immediately. New submissions appear in Results as pending until that batch finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("Overview") {
            if isEditingOverviewConfig {
                ModelTextField(title: "Answer generation model", text: $draftAnswerModelID)
                ModelTextField(title: "Grading model", text: $draftGradingModelID)
                Toggle("Enable validation model", isOn: $draftValidationEnabled)
                if draftValidationEnabled {
                    ModelTextField(title: "Validation model", text: $draftValidationModelID)
                }
            } else {
                LabeledContent("Answer model", value: session.answerModelID)
                LabeledContent("Grading model", value: session.gradingModelID)
                LabeledContent("Validation model", value: session.validationModelLabel)
            }
            LabeledContent("Point mode", value: session.pointModeLabel)
            LabeledContent("Questions", value: "\(session.sortedQuestions.count)")
            LabeledContent("Saved submissions", value: "\(session.sortedSubmissions.count)")
            LabeledContent("Total points", value: ScoreFormatting.scoreString(session.totalPossiblePoints))
            LabeledContent("API cost", value: session.sessionCostLabel)
            LabeledContent("Batch pages / submission", value: session.maxPagesLabel)

            if isEditingOverviewConfig {
                Toggle("Integer points only", isOn: $draftIntegerPointsOnly)
                Toggle("Relaxed grading mode", isOn: $draftRelaxedGradingMode)
                Toggle("Session ended", isOn: $draftSessionEnded)
            } else {
                LabeledContent("Integer points only", value: session.integerPointsOnlyEnabled ? "On" : "Off")
                LabeledContent("Relaxed grading mode", value: session.relaxedModeLabel)
                LabeledContent("Session ended", value: session.isFinished ? "On" : "Off")
            }
        }

        Section("Advanced API Settings") {
            if isEditingOverviewConfig {
                APIAdvancedSettingsEditor(
                    validationEnabled: $draftValidationEnabled,
                    answerReasoningEffort: $draftAnswerReasoningEffort,
                    gradingReasoningEffort: $draftGradingReasoningEffort,
                    validationReasoningEffort: $draftValidationReasoningEffort,
                    answerVerbosity: $draftAnswerVerbosity,
                    gradingVerbosity: $draftGradingVerbosity,
                    validationVerbosity: $draftValidationVerbosity,
                    answerServiceTier: $draftAnswerServiceTier,
                    gradingServiceTier: $draftGradingServiceTier,
                    validationServiceTier: $draftValidationServiceTier
                )
            }

            LabeledContent("Answer reasoning", value: session.answerReasoningLabel)
            LabeledContent("Grading reasoning", value: session.gradingReasoningLabel)
            LabeledContent("Validation reasoning", value: session.validationReasoningLabel)
            LabeledContent("Answer verbosity", value: session.answerVerbosityLabel)
            LabeledContent("Grading verbosity", value: session.gradingVerbosityLabel)
            LabeledContent("Validation verbosity", value: session.validationVerbosityLabel)
            LabeledContent("Answer tier", value: session.answerServiceTierLabel)
            LabeledContent("Grading tier", value: session.gradingServiceTierLabel)
            LabeledContent("Validation tier", value: session.validationServiceTierLabel)

            if isEditingOverviewConfig {
                HStack {
                    Button("Cancel") {
                        cancelOverviewConfigEditing()
                    }

                    Spacer()

                    Button("Save Config") {
                        saveOverviewConfigEdits()
                    }
                    .disabled(!canSaveOverviewConfig)
                }
            } else {
                Button("Edit Config") {
                    beginOverviewConfigEditing()
                }
            }
        }
    }

    @ViewBuilder
    private var rubricSections: some View {
        if session.questions.isEmpty {
            Section("Rubric") {
                Text("No rubric yet. Scan the blank assignment from the Overview tab first.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Master Pages") {
                ImageStripView(pageData: session.masterScans())
            }

            Section("Overall Rules") {
                NavigationLink {
                    OverallRulesEditorView(session: session)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Session-wide grading rules")
                            .font(.headline)
                        Text((session.overallGradingRules?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? session.overallGradingRules! : "No overall rules added yet."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
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

    @ViewBuilder
    private var resultsSections: some View {
        Section("Export") {
            Button {
                Task {
                    await exportCSV()
                }
            } label: {
                Label("Export Session CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(session.sortedSubmissions.isEmpty)

            Button {
                Task {
                    await exportPackage()
                }
            } label: {
                Label("Export Full Session Package", systemImage: "archivebox")
            }
            .disabled(session.sortedSubmissions.isEmpty)
        }

        Section("Search") {
            TextField("Search by student name", text: $resultsSearchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }

        Section("Saved Results") {
            if hasPendingBatchSubmissions {
                Button {
                    Task {
                        await refreshPendingBatchSubmissions(force: true)
                    }
                } label: {
                    Label(isRefreshingPendingBatches ? "Checking Pending Jobs..." : "Check Pending Jobs", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshingPendingBatches)

                Text("Batch submissions show up here immediately as pending. Pull results later without blocking the rest of the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if filteredSubmissions.isEmpty {
                Text("No student submissions saved yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredSubmissions) { submission in
                    Group {
                        if submission.isProcessingCompleted {
                            Button {
                                selectedSubmission = submission
                            } label: {
                                SubmissionRow(submission: submission)
                            }
                            .buttonStyle(.plain)
                        } else {
                            SubmissionRow(submission: submission)
                        }
                    }
                }
            }
        }

    }

    private var hasAPIKey: Bool {
        let key = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSaveOverviewConfig: Bool {
        !draftAnswerModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draftGradingModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!draftValidationEnabled || !draftValidationModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func beginOverviewConfigEditing() {
        draftAnswerModelID = session.answerModelID
        draftGradingModelID = session.gradingModelID
        draftValidationModelID = session.validationModelIDResolved
        draftValidationEnabled = session.validationEnabledResolved
        draftIntegerPointsOnly = session.integerPointsOnlyEnabled
        draftRelaxedGradingMode = session.relaxedGradingModeEnabled
        draftSessionEnded = session.isFinished
        draftAnswerReasoningEffort = session.answerReasoningEffort
        draftGradingReasoningEffort = session.gradingReasoningEffort
        draftValidationReasoningEffort = session.validationReasoningEffort
        draftAnswerVerbosity = session.answerVerbosity
        draftGradingVerbosity = session.gradingVerbosity
        draftValidationVerbosity = session.validationVerbosity
        draftAnswerServiceTier = session.answerServiceTier
        draftGradingServiceTier = session.gradingServiceTier
        draftValidationServiceTier = session.validationServiceTier
        isEditingOverviewConfig = true
    }

    private func cancelOverviewConfigEditing() {
        isEditingOverviewConfig = false
    }

    private func saveOverviewConfigEdits() {
        let wasIntegerOnly = session.integerPointsOnlyEnabled

        session.answerModelID = draftAnswerModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        session.gradingModelID = draftGradingModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        session.validationEnabled = draftValidationEnabled
        session.validationModelID = draftValidationEnabled ? draftValidationModelID.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        session.integerPointsOnly = draftIntegerPointsOnly
        session.relaxedGradingMode = draftRelaxedGradingMode
        session.isFinished = draftSessionEnded
        session.answerReasoningEffort = draftAnswerReasoningEffort
        session.gradingReasoningEffort = draftGradingReasoningEffort
        session.validationReasoningEffort = draftValidationReasoningEffort
        session.answerVerbosity = draftAnswerVerbosity
        session.gradingVerbosity = draftGradingVerbosity
        session.validationVerbosity = draftValidationVerbosity
        session.answerServiceTier = draftAnswerServiceTier
        session.gradingServiceTier = draftGradingServiceTier
        session.validationServiceTier = draftValidationServiceTier

        if !wasIntegerOnly && draftIntegerPointsOnly {
            normalizeSessionToIntegerPoints()
        }

        try? modelContext.save()
        isEditingOverviewConfig = false
    }

    private func startMasterScan() {
        guard canStartAnyCapture else {
            alertItem = AlertItem(message: "No supported capture source is available on this device.")
            return
        }

        showPreparingOverlay(title: "Preparing scan options")
        pendingScanIntent = .master
        DispatchQueue.main.async {
            showingScanSourcePicker = true
        }
    }

    private func startStudentScan() {
        guard canStartAnyCapture else {
            alertItem = AlertItem(message: "No supported capture source is available on this device.")
            return
        }

        showPreparingOverlay(title: "Preparing scan options")
        pendingScanIntent = .student
        DispatchQueue.main.async {
            showingScanSourcePicker = true
        }
    }

    private func startBatchStudentScan() {
        guard canStartAnyCapture else {
            alertItem = AlertItem(message: "No supported capture source is available on this device.")
            return
        }

        pendingBatchPagesPerSubmission = nil
        showPreparingOverlay(title: "Preparing scan options")
        pendingScanIntent = .batch
        DispatchQueue.main.async {
            showingScanSourcePicker = true
        }
    }

    private var canStartAnyCapture: Bool {
        VNDocumentCameraViewController.isSupported || CameraCaptureViewController.isCaptureAvailable
    }

    private func selectScanSource(_ source: ScanCaptureSource) {
        guard let intent = pendingScanIntent else { return }

        switch source {
        case .documentScanner:
            guard VNDocumentCameraViewController.isSupported else {
                alertItem = AlertItem(message: "Document scanning is not available on this device.")
                pendingScanIntent = nil
                return
            }
        case .camera:
            guard CameraCaptureViewController.isCaptureAvailable else {
                alertItem = AlertItem(message: "Camera capture is not available on this device.")
                pendingScanIntent = nil
                return
            }
        }

        pendingScanSource = source

        switch intent {
        case .batch:
            pendingBatchPagesPerSubmission = nil
            showPreparingOverlay(title: "Preparing batch setup")
            DispatchQueue.main.async {
                showingBatchScanSetup = true
            }
        case .master, .student:
            showPreparingOverlay(title: "Preparing \(source.buttonTitle)")
            DispatchQueue.main.async {
                presentCaptureFlow(kind: intent, source: source)
            }
        }
    }

    private func presentCaptureFlow(kind: ScanIntent, source: ScanCaptureSource) {
        activeCaptureFlow = ActiveCaptureFlow(kind: kind, source: source)
    }

    private func handleCaptureCompletion(_ images: [UIImage], for flow: ActiveCaptureFlow) {
        activeCaptureFlow = nil

        switch flow.kind {
        case .master:
            pendingScanIntent = nil
            pendingScanSource = nil
            Task {
                await generateRubric(from: images)
            }
        case .student:
            pendingScanIntent = nil
            pendingScanSource = nil
            Task {
                await gradeSubmission(from: images)
            }
        case .batch:
            let pagesPerSubmission = pendingBatchPagesPerSubmission ?? session.maxPagesPerSubmission ?? 0
            pendingBatchPagesPerSubmission = nil
            pendingScanIntent = nil
            pendingScanSource = nil
            Task {
                await gradeSubmissionBatch(from: images, pagesPerSubmission: pagesPerSubmission)
            }
        }
    }

    private func handleCaptureCancellation(for flow: ActiveCaptureFlow) {
        activeCaptureFlow = nil
        if flow.kind == .batch {
            pendingBatchPagesPerSubmission = nil
        }
        pendingScanIntent = nil
        pendingScanSource = nil
        clearPreparingOverlay()
    }

    private func handleCaptureError(_ error: Error, for flow: ActiveCaptureFlow) {
        handleCaptureCancellation(for: flow)
        alertItem = AlertItem(message: error.localizedDescription)
    }

    @MainActor
    private func generateRubric(from images: [UIImage]) async {
        busyState = BusyOverlayState(title: "Preparing scan", detail: "Optimizing captured pages")
        let pageData = await ScanImagePreparation.makeJPEGPageData(from: images)
        guard !pageData.isEmpty else {
            busyState = nil
            alertItem = AlertItem(message: "The scan did not contain any pages.")
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        defer { busyState = nil }

        do {
            updateBusyPresentation(title: "Generating answer key", detail: "Uploading optimized scan pages")
            let result = try await OpenAIService.shared.generateAnswerKey(
                apiKey: apiKey,
                modelID: session.answerModelID,
                sessionTitle: session.title,
                pageData: pageData,
                reasoningEffort: session.answerReasoningEffort,
                verbosity: session.answerVerbosity,
                serviceTier: session.answerServiceTier,
                streamHandler: { event in
                    await MainActor.run {
                        applyBusyStreamEvent(
                            event,
                            sourceID: "answer-key",
                            sourceTitle: "Answer Key"
                        )
                    }
                }
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
        busyState = BusyOverlayState(title: "Preparing submission", detail: "Optimizing captured pages")
        let pageData = await ScanImagePreparation.makeJPEGPageData(from: images)
        guard !pageData.isEmpty else {
            busyState = nil
            alertItem = AlertItem(message: "The scan did not contain any pages.")
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        let processor = makeSubmissionProcessor(apiKey: apiKey)
        defer { busyState = nil }

        do {
            updateBusyPresentation(title: "Grading submission", detail: "Sending optimized pages for grading")

            let processed = try await processor.grade(
                pageData: pageData,
                requestNamespace: "single-submission",
                requestLabelPrefix: "Submission",
                progress: { stage in
                    await MainActor.run {
                        updateBusyPresentation(
                            title: "Grading submission",
                            detail: stage.singleSubmissionDetail
                        )
                    }
                },
                transcript: { update in
                    await MainActor.run {
                        applyBusyStreamEvent(
                            update.event,
                            sourceID: update.requestID,
                            sourceTitle: update.title
                        )
                    }
                }
            )

            for usage in processed.usageSummaries {
                recordUsage(usage, apiKey: apiKey)
            }

            submissionDraft = processed.draft
        } catch {
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    @MainActor
    private func gradeSubmissionBatch(from images: [UIImage], pagesPerSubmission: Int) async {
        busyState = BusyOverlayState(title: "Preparing batch job", detail: "Optimizing captured pages")
        let allPageData = await ScanImagePreparation.makeJPEGPageData(from: images)

        let pageGroups: [[Data]]
        do {
            pageGroups = try SubmissionBatchOrganizer.split(
                pages: allPageData,
                pagesPerSubmission: pagesPerSubmission
            )
        } catch {
            alertItem = AlertItem(message: error.localizedDescription)
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        defer { busyState = nil }

        let placeholders = createPendingBatchSubmissions(for: pageGroups)

        do {
            updateBusyPresentation(title: "Submitting batch job", detail: "Uploading requests to OpenAI")

            let batchInputs = zip(placeholders, pageGroups).compactMap { submission, pageData -> OpenAIBatchSubmissionInput? in
                guard let customID = submission.remoteBatchRequestID else { return nil }
                return OpenAIBatchSubmissionInput(
                    customID: customID,
                    pageData: pageData
                )
            }

            let creation = try await OpenAIService.shared.createSubmissionGradingBatch(
                apiKey: apiKey,
                modelID: session.gradingModelID,
                rubric: session.sortedQuestions.map(\.snapshot),
                overallRules: session.overallGradingRules,
                submissions: batchInputs,
                integerPointsOnly: session.integerPointsOnlyEnabled,
                relaxedGradingMode: session.relaxedGradingModeEnabled,
                reasoningEffort: session.gradingReasoningEffort,
                verbosity: session.gradingVerbosity
            )

            for submission in placeholders {
                submission.remoteBatchID = creation.batchID
                submission.processingStateRaw = StudentSubmissionProcessingState.pending.rawValue
                submission.processingDetail = detailTextForBatchStatus(
                    status: creation.status,
                    requestCounts: nil
                )
            }

            try? modelContext.save()
            selectedTab = .results

            alertItem = AlertItem(
                message: "Submitted \(placeholders.count) submissions to the OpenAI Batch API. They now appear in Results as pending and will update when the batch finishes."
            )

            await refreshPendingBatchSubmissions(force: true)
        } catch {
            removePendingBatchSubmissions(placeholders)
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    private func saveRubric(overallRules: String, approvedDrafts: [RubricQuestionDraft], pageData: [Data]) {
        session.setMasterScans(pageData)
        let trimmedOverallRules = overallRules.trimmingCharacters(in: .whitespacesAndNewlines)
        session.overallGradingRules = trimmedOverallRules.isEmpty ? nil : trimmedOverallRules

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

    private func saveSubmission(_ approvedDraft: SubmissionDraft, persistChanges: Bool = true) {
        let submission = StudentSubmission(
            studentName: approvedDraft.studentName.trimmingCharacters(in: .whitespacesAndNewlines),
            nameNeedsReview: approvedDraft.nameNeedsReview,
            overallNotes: approvedDraft.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            teacherReviewed: true,
            totalScore: approvedDraft.totalScore,
            maxScore: approvedDraft.maxScore,
            processingStateRaw: StudentSubmissionProcessingState.completed.rawValue,
            session: session
        )
        submission.setScans(approvedDraft.pageData)
        submission.setQuestionGrades(approvedDraft.grades)
        modelContext.insert(submission)
        session.submissions.append(submission)
        if persistChanges {
            try? modelContext.save()
        }
    }

    private func saveSubmissions(_ approvedDrafts: [SubmissionDraft]) {
        for draft in approvedDrafts {
            saveSubmission(draft.normalized(integerPointsOnly: session.integerPointsOnlyEnabled), persistChanges: false)
        }
        try? modelContext.save()
    }

    private func createPendingBatchSubmissions(for pageGroups: [[Data]]) -> [StudentSubmission] {
        let placeholders = pageGroups.enumerated().map { index, pageData in
            let submission = StudentSubmission(
                studentName: "Pending Submission \(index + 1)",
                nameNeedsReview: false,
                overallNotes: "OpenAI batch job submitted. Result pending.",
                teacherReviewed: false,
                totalScore: 0,
                maxScore: session.totalPossiblePoints,
                processingStateRaw: StudentSubmissionProcessingState.pending.rawValue,
                processingDetail: "Preparing batch submission",
                remoteBatchRequestID: "submission-\(UUID().uuidString)",
                session: session
            )
            submission.setScans(pageData)
            modelContext.insert(submission)
            session.submissions.append(submission)
            return submission
        }

        try? modelContext.save()
        return placeholders
    }

    private func removePendingBatchSubmissions(_ submissions: [StudentSubmission]) {
        for submission in submissions {
            if let index = session.submissions.firstIndex(where: { $0.id == submission.id }) {
                session.submissions.remove(at: index)
            }
            modelContext.delete(submission)
        }
        try? modelContext.save()
    }

    @MainActor
    private func refreshPendingBatchSubmissions(force: Bool) async {
        guard hasPendingBatchSubmissions else { return }
        guard !isRefreshingPendingBatches else { return }
        guard hasAPIKey else { return }

        if
            !force,
            let lastPendingBatchRefreshAt,
            Date.now.timeIntervalSince(lastPendingBatchRefreshAt) < 15
        {
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        let batchIDs = Array(Set(session.sortedSubmissions.compactMap { submission in
            submission.isProcessingPending ? submission.remoteBatchID : nil
        }))

        guard !batchIDs.isEmpty else { return }

        isRefreshingPendingBatches = true
        lastPendingBatchRefreshAt = .now
        defer { isRefreshingPendingBatches = false }

        for batchID in batchIDs {
            do {
                let snapshot = try await OpenAIService.shared.fetchBatchStatus(
                    apiKey: apiKey,
                    batchID: batchID
                )
                try await applyBatchStatusSnapshot(snapshot, apiKey: apiKey)
            } catch {
                markBatchSubmissions(
                    batchID: batchID,
                    detail: "Unable to refresh batch status. \(error.localizedDescription)"
                )
            }
        }

        try? modelContext.save()
    }

    @MainActor
    private func applyBatchStatusSnapshot(_ snapshot: OpenAIBatchStatusSnapshot, apiKey: String) async throws {
        switch snapshot.status {
        case "completed":
            try await finalizeCompletedBatch(snapshot, apiKey: apiKey)
        case "failed", "expired", "cancelled":
            let message = snapshot.errors.first ?? detailTextForBatchStatus(
                status: snapshot.status,
                requestCounts: snapshot.requestCounts
            )
            markBatchSubmissionsAsFailed(batchID: snapshot.batchID, message: message)
        default:
            markBatchSubmissions(
                batchID: snapshot.batchID,
                detail: detailTextForBatchStatus(
                    status: snapshot.status,
                    requestCounts: snapshot.requestCounts
                )
            )
        }
    }

    @MainActor
    private func finalizeCompletedBatch(_ snapshot: OpenAIBatchStatusSnapshot, apiKey: String) async throws {
        let results: [OpenAIBatchSubmissionResult<SubmissionPayload>]
        if let outputFileID = snapshot.outputFileID {
            results = try await OpenAIService.shared.fetchSubmissionBatchResults(
                apiKey: apiKey,
                modelID: session.gradingModelID,
                outputFileID: outputFileID
            )
        } else {
            results = []
        }

        let errors: [OpenAIBatchSubmissionError]
        if let errorFileID = snapshot.errorFileID {
            errors = try await OpenAIService.shared.fetchBatchErrors(
                apiKey: apiKey,
                errorFileID: errorFileID
            )
        } else {
            errors = []
        }

        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })
        let errorsByID = Dictionary(uniqueKeysWithValues: errors.map { ($0.customID, $0.message) })
        let pendingSubmissions = session.sortedSubmissions.filter {
            $0.isProcessingPending && $0.remoteBatchID == snapshot.batchID
        }

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                markSubmissionFailed(
                    submission,
                    message: "This batch submission is missing its request identifier."
                )
                continue
            }

            if let result = resultsByID[requestID] {
                applyCompletedBatchResult(result, to: submission, apiKey: apiKey)
            } else if let message = errorsByID[requestID] {
                markSubmissionFailed(submission, message: message)
            } else {
                markSubmissionFailed(
                    submission,
                    message: "OpenAI completed the batch but did not return a result for this submission."
                )
            }
        }
    }

    private func applyCompletedBatchResult(
        _ result: OpenAIBatchSubmissionResult<SubmissionPayload>,
        to submission: StudentSubmission,
        apiKey: String
    ) {
        let draft = SubmissionDraft.from(
            payload: result.payload,
            rubricSnapshots: session.sortedQuestions.map(\.snapshot),
            pageData: submission.scans(),
            integerPointsOnly: session.integerPointsOnlyEnabled
        )
        .normalized(integerPointsOnly: session.integerPointsOnlyEnabled)

        submission.studentName = draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.nameNeedsReview = draft.nameNeedsReview
        submission.overallNotes = draft.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.teacherReviewed = false
        submission.processingStateRaw = StudentSubmissionProcessingState.completed.rawValue
        submission.processingDetail = nil
        submission.setQuestionGrades(draft.grades)
        recordUsage(result.usage, apiKey: apiKey)
    }

    private func markBatchSubmissions(batchID: String, detail: String) {
        for submission in session.sortedSubmissions where submission.isProcessingPending && submission.remoteBatchID == batchID {
            submission.processingDetail = detail
        }
    }

    private func markBatchSubmissionsAsFailed(batchID: String, message: String) {
        for submission in session.sortedSubmissions where submission.isProcessingPending && submission.remoteBatchID == batchID {
            markSubmissionFailed(submission, message: message)
        }
    }

    private func markSubmissionFailed(_ submission: StudentSubmission, message: String) {
        submission.processingStateRaw = StudentSubmissionProcessingState.failed.rawValue
        submission.processingDetail = message
        submission.overallNotes = message
        submission.teacherReviewed = false
        submission.setQuestionGrades([])
        submission.totalScore = 0
        submission.maxScore = session.totalPossiblePoints
    }

    private func detailTextForBatchStatus(
        status: String,
        requestCounts: OpenAIBatchRequestCounts?
    ) -> String {
        let countSuffix: String
        if let requestCounts {
            let remaining = max(requestCounts.total - requestCounts.completed - requestCounts.failed, 0)
            countSuffix = " \(requestCounts.completed) completed, \(requestCounts.failed) failed, \(remaining) remaining."
        } else {
            countSuffix = ""
        }

        switch status {
        case "validating":
            return "OpenAI is validating the uploaded batch input.\(countSuffix)"
        case "in_progress":
            return "OpenAI is grading the batch.\(countSuffix)"
        case "finalizing":
            return "OpenAI is preparing the batch output files.\(countSuffix)"
        case "completed":
            return "Batch completed."
        case "expired":
            return "OpenAI could not finish this batch within the 24-hour window."
        case "cancelled":
            return "This batch was cancelled."
        case "failed":
            return "OpenAI rejected this batch job."
        default:
            return "Batch status: \(status).\(countSuffix)"
        }
    }

    @MainActor
    private func exportCSV() async {
        showPreparingOverlay(title: "Preparing CSV export")
        defer { clearPreparingOverlay() }
        await Task.yield()

        do {
            shareItem = ShareItem(url: try CSVExporter.temporaryFileURL(for: session))
        } catch {
            alertItem = AlertItem(message: "Unable to export CSV. \(error.localizedDescription)")
        }
    }

    @MainActor
    private func exportPackage() async {
        showPreparingOverlay(title: "Preparing full export", detail: "Building ZIP archive")
        defer { clearPreparingOverlay() }
        await Task.yield()

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

    @MainActor
    private func updateBusyState(_ mutate: (inout BusyOverlayState) -> Void) {
        var state = busyState ?? BusyOverlayState(title: "Working")
        mutate(&state)
        busyState = state
    }

    @MainActor
    private func showPreparingOverlay(title: String, detail: String? = nil) {
        guard busyState == nil else { return }
        preparingState = BusyOverlayState(title: title, detail: detail)
    }

    @MainActor
    private func clearPreparingOverlay() {
        preparingState = nil
    }

    @MainActor
    private func updateBusyPresentation(title: String, detail: String? = nil) {
        updateBusyState { state in
            state.setPresentation(title: title, detail: detail)
        }
    }

    @MainActor
    private func applyBusyProgressSnapshot(_ snapshot: BatchProgressSnapshot) {
        updateBusyState { state in
            state.apply(snapshot: snapshot)
        }
    }

    @MainActor
    private func applyBusyStreamEvent(_ event: OpenAIStreamEvent, sourceID: String, sourceTitle: String) {
        updateBusyState { state in
            state.applyStreamEvent(event, sourceID: sourceID, sourceTitle: sourceTitle)
        }
    }

    private func makeSubmissionProcessor(apiKey: String) -> SubmissionProcessor {
        SubmissionProcessor(
            config: SubmissionProcessorConfig(
                apiKey: apiKey,
                gradingModelID: session.gradingModelID,
                validationModelID: session.validationEnabledResolved ? session.validationModelIDResolved : nil,
                rubricSnapshots: session.sortedQuestions.map(\.snapshot),
                overallRules: session.overallGradingRules,
                integerPointsOnly: session.integerPointsOnlyEnabled,
                relaxedGradingMode: session.relaxedGradingModeEnabled,
                gradingReasoningEffort: session.gradingReasoningEffort,
                gradingVerbosity: session.gradingVerbosity,
                gradingServiceTier: session.gradingServiceTier,
                validationReasoningEffort: session.validationReasoningEffort,
                validationVerbosity: session.validationVerbosity,
                validationServiceTier: session.validationServiceTier
            )
        )
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

    private var hasPendingBatchSubmissions: Bool {
        session.submissions.contains(where: \.isProcessingPending)
    }

    private var filteredSubmissions: [StudentSubmission] {
        let trimmed = resultsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty
            ? session.submissions
            : session.submissions.filter {
                $0.listDisplayName.localizedCaseInsensitiveContains(trimmed)
            }
        return filtered.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }
}
