import SwiftUI
import SwiftData
import UIKit
import VisionKit
import ImageIO
import UniformTypeIdentifiers

private enum ScanImagePreparation {
    static let optimizedMaxPixelSize: CGFloat = 2200
    static let optimizedJPEGQuality: CGFloat = 0.82

    static func makeJPEGPageData(
        from fileURLs: [URL],
        progress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [Data] {
        let optimizedFiles = await makeOptimizedJPEGFiles(from: fileURLs, progress: progress)
        defer { ScanCaptureStorage.removeFiles(at: optimizedFiles) }

        return await Task.detached(priority: .userInitiated) {
            optimizedFiles.compactMap { fileURL in
                autoreleasepool {
                    try? Data(contentsOf: fileURL, options: .mappedIfSafe)
                }
            }
        }.value
    }

    static func makeOptimizedJPEGFiles(
        from fileURLs: [URL],
        progress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            guard let outputDirectory = try? ScanCaptureStorage.makeCaptureDirectory() else { return [] }

            var optimizedURLs: [URL] = []
            optimizedURLs.reserveCapacity(fileURLs.count)

            for (index, fileURL) in fileURLs.enumerated() {
                if let optimizedData = autoreleasepool(invoking: {
                    optimizedJPEGData(from: fileURL)
                }) {
                    let optimizedURL = outputDirectory.appendingPathComponent(String(format: "optimized-%04d.jpg", index + 1))
                    do {
                        try optimizedData.write(to: optimizedURL, options: .atomic)
                        optimizedURLs.append(optimizedURL)
                    } catch {
                        break
                    }
                }

                if let progress {
                    await progress(index + 1, fileURLs.count)
                }
            }

            return optimizedURLs
        }.value
    }

    private static func optimizedJPEGData(from fileURL: URL) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(optimizedMaxPixelSize.rounded()), 1),
        ]

        guard let imageRef = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let outputData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                outputData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: optimizedJPEGQuality,
        ]
        CGImageDestinationAddImage(destination, imageRef, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }
}

private enum SessionSectionTab: String, CaseIterable, Identifiable {
    case rubric = "Rubric"
    case overview = "Overview"
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

private struct PreparedSingleScanRequest {
    let apiKey: String
    let pageData: [Data]
}

@MainActor
struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
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
    @State private var showingRegradeAllConfirmation = false
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
    @State private var draftValidationMaxAttempts = 2
    @State private var isSavingOverviewConfig = false
    @State private var isRefreshingPendingRubric = false
    @State private var lastPendingRubricRefreshAt: Date?
    @State private var isRefreshingPendingBatches = false
    @State private var lastPendingBatchRefreshAt: Date?
    @State private var submissionBeingRegraded: StudentSubmission?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(SessionSectionTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            TabView(selection: $selectedTab) {
                Form {
                    rubricSections
                }
                .tag(SessionSectionTab.rubric)

                Form {
                    overviewSections
                }
                .tag(SessionSectionTab.overview)

                Form {
                    resultsSections
                }
                .tag(SessionSectionTab.results)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
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
                    onComplete: { fileURLs in
                        handleCaptureCompletion(fileURLs, for: flow)
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
                    onComplete: { fileURLs in
                        handleCaptureCompletion(fileURLs, for: flow)
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
        .sheet(item: $submissionDraft, onDismiss: {
            submissionBeingRegraded = nil
        }) { draft in
            SubmissionReviewView(
                draft: draft,
                integerPointsOnly: session.integerPointsOnlyEnabled,
                showsSaveAndScanNext: submissionBeingRegraded == nil,
                onSave: { approvedDraft in
                    if let submissionBeingRegraded {
                        updateSubmission(submissionBeingRegraded, with: approvedDraft)
                    } else {
                        saveSubmission(approvedDraft)
                    }
                    self.submissionBeingRegraded = nil
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
            SavedSubmissionDetailView(
                submission: submission,
                onRegrade: {
                    selectedSubmission = nil
                    Task {
                        await regradeSubmission(submission)
                    }
                },
                onDelete: {
                    deleteSubmission(submission)
                }
            )
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(item: $alertItem) { item in
            Alert(title: Text("HGrader"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Delete this session?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) {
                deleteSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the rubric, scans, and saved results for this session.")
        }
        .confirmationDialog("Regrade all saved scans?", isPresented: $showingRegradeAllConfirmation, titleVisibility: .visible) {
            Button("Regrade All Saved Scans") {
                Task {
                    await regradeAllSavedSubmissions()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This keeps the scanned pages, clears the current grading state, and submits every saved submission for regrading.")
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
            await refreshPendingRubricGeneration(force: false)
            await refreshPendingBatchSubmissions(force: false)
        }
        .task(id: pendingRubricPollingID) {
            guard !pendingRubricPollingID.isEmpty else { return }
            while !Task.isCancelled && session.hasPendingRubricGeneration {
                await refreshPendingRubricGeneration(force: false)
                guard session.hasPendingRubricGeneration else { break }
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
        .overlay {
            if let overlayState = busyState ?? preparingState {
                BusyOverlay(state: overlayState)
            }
        }
        .keyboardDismissToolbar()
        .feedbackToast()
        .activityOverlay(isPresented: isSavingOverviewConfig, text: "Saving config...")
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
                .disabled(!hasAPIKey || session.hasPendingRubricGeneration)

                Text(hasAPIKey ? "Scan the teacher copy or blank exam pages, then review the generated rubric from the Rubric tab before grading students." : "Add your API key in Settings first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !session.masterScans().isEmpty {
                Section("Student Scans") {
                    Button {
                        startBatchStudentScan()
                    } label: {
                        Label("Batch Add Student Scans", systemImage: "square.stack.3d.down.right")
                    }
                    .disabled(session.isFinished)

                    Text("You can scan student submissions now, even before the rubric is approved. HGrader will save the scans first and let you submit them all after the rubric is ready.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

        Section("Summary") {
            LabeledContent("Questions", value: "\(session.questions.count)")
            LabeledContent("Saved submissions", value: "\(session.submissions.count)")
            LabeledContent("Total points", value: ScoreFormatting.scoreString(session.totalPossiblePoints))

            if let overallAverageScore {
                LabeledContent("Average total score") {
                    Text("\(ScoreFormatting.scoreString(overallAverageScore)) / \(ScoreFormatting.scoreString(session.totalPossiblePoints))")
                        .foregroundStyle(summaryColor(for: overallAveragePercentage ?? 0))
                }
            } else {
                LabeledContent("Average total score", value: "No graded submissions yet")
            }

            if !session.sortedQuestions.isEmpty {
                ForEach(session.sortedQuestions) { question in
                    LabeledContent(question.displayLabel) {
                        if let average = averageScore(for: question) {
                            let percentage = average / max(question.maxPoints, 0.001)
                            Text("\(ScoreFormatting.scoreString(average)) / \(ScoreFormatting.scoreString(question.maxPoints))")
                                .foregroundStyle(summaryColor(for: percentage))
                        } else {
                            Text("No grades yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        Section("Settings") {
            if isEditingOverviewConfig {
                Toggle("Integer points only", isOn: $draftIntegerPointsOnly)
                Toggle("Relaxed grading mode", isOn: $draftRelaxedGradingMode)
                Toggle("Session ended", isOn: $draftSessionEnded)
            }

            LabeledContent("Point mode", value: session.pointModeLabel)
            LabeledContent("Batch pages / submission", value: session.maxPagesLabel)
            LabeledContent("Integer points only", value: session.integerPointsOnlyEnabled ? "On" : "Off")
            LabeledContent("Relaxed grading mode", value: session.relaxedModeLabel)
            LabeledContent("Session ended", value: session.isFinished ? "On" : "Off")
        }

        Section("Advanced API Settings") {
            if isEditingOverviewConfig {
                ModelTextField(title: "Answer generation model", text: $draftAnswerModelID)
                ModelTextField(title: "Grading model", text: $draftGradingModelID)
                Toggle("Enable validation model", isOn: $draftValidationEnabled)
                if draftValidationEnabled {
                    ModelTextField(title: "Validation model", text: $draftValidationModelID)
                }
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
                    validationServiceTier: $draftValidationServiceTier,
                    validationMaxAttempts: $draftValidationMaxAttempts
                )
            }

            LabeledContent("Answer model", value: session.answerModelID)
            LabeledContent("Grading model", value: session.gradingModelID)
            LabeledContent("Validation model", value: session.validationModelLabel)
            LabeledContent("API cost", value: session.sessionCostLabel)
            LabeledContent("Answer reasoning", value: session.answerReasoningLabel)
            LabeledContent("Grading reasoning", value: session.gradingReasoningLabel)
            LabeledContent("Validation reasoning", value: session.validationReasoningLabel)
            LabeledContent("Answer verbosity", value: session.answerVerbosityLabel)
            LabeledContent("Grading verbosity", value: session.gradingVerbosityLabel)
            LabeledContent("Validation verbosity", value: session.validationVerbosityLabel)
            LabeledContent("Answer tier", value: session.answerServiceTierLabel)
            LabeledContent("Grading tier", value: session.gradingServiceTierLabel)
            LabeledContent("Validation tier", value: session.validationServiceTierLabel)
            LabeledContent("Validation max attempts", value: session.validationMaxAttemptsLabel)

            if isEditingOverviewConfig {
                HStack {
                    Button("Cancel") {
                        cancelOverviewConfigEditing()
                    }

                    Spacer()

                    Button {
                        beginSaveOverviewConfig()
                    } label: {
                        if isSavingOverviewConfig {
                            ProgressView()
                        } else {
                            Text("Save Config")
                        }
                    }
                    .disabled(!canSaveOverviewConfig || isSavingOverviewConfig)
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
                if session.hasPendingRubricReview {
                    Button {
                        openPendingRubricReview()
                    } label: {
                        Label("Review Generated Answer Key", systemImage: "checklist")
                    }
                }

                Text(
                    session.hasPendingRubricGeneration
                        ? "The answer key request has been sent. Track its progress here and review it as soon as it finishes."
                        : session.hasPendingRubricReview
                            ? "A generated answer key is ready to review and approve."
                            : session.hasFailedRubricGeneration
                                ? "The last answer key request did not finish. Review the status below, then rescan when ready."
                                : "No rubric yet. Scan the blank assignment from the Overview tab first."
                )
                    .foregroundStyle(.secondary)
            }

            if !session.masterScans().isEmpty {
                Section(session.hasPendingRubricGeneration ? "Pending Master Pages" : "Master Pages") {
                    ImageStripView(pageData: session.masterScans())
                }
            }

            if session.hasPendingRubricGeneration || session.hasFailedRubricGeneration || session.hasPendingRubricReview {
                Section("Answer Key Status") {
                    if session.hasPendingRubricGeneration {
                        Button {
                            Task {
                                await refreshPendingRubricGeneration(force: true)
                            }
                        } label: {
                            Label(isRefreshingPendingRubric ? "Checking Answer Key..." : "Check Answer Key", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRefreshingPendingRubric)

                        if isRefreshingPendingRubric {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking OpenAI for the latest answer key status...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let lastPendingRubricRefreshAt {
                            Text("Last checked \(lastPendingRubricRefreshAt.formatted(date: .omitted, time: .shortened)).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let detail = session.rubricProcessingDetail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if session.hasFailedRubricGeneration {
                        Button {
                            startMasterScan()
                        } label: {
                            Label("Rescan Blank Assignment", systemImage: "arrow.clockwise.circle")
                        }
                        .disabled(!hasAPIKey)
                    }
                }
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
            .disabled(session.submissions.isEmpty)

            Button {
                Task {
                    await exportPackage()
                }
            } label: {
                Label("Export Full Session Package", systemImage: "archivebox")
            }
            .disabled(session.submissions.isEmpty)

            Button {
                showingRegradeAllConfirmation = true
            } label: {
                Label("Regrade All Saved Scans", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(session.submissions.isEmpty || hasRefreshablePendingBatchSubmissions || !hasAPIKey || session.questions.isEmpty)

            if hasQueuedBatchSubmissions {
                Button {
                    Task {
                        await submitQueuedScansForGrading()
                    }
                } label: {
                    Label("Submit All Queued Scans", systemImage: "paperplane")
                }
                .disabled(!hasAPIKey || session.questions.isEmpty || hasRefreshablePendingBatchSubmissions)
            }
        }

        Section("Search") {
            TextField("Search by student name", text: $resultsSearchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }

        Section("Saved Results") {
            if hasRefreshablePendingBatchSubmissions {
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

                if isRefreshingPendingBatches {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking OpenAI for batch updates...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let lastPendingBatchRefreshAt {
                    Text("Last checked \(lastPendingBatchRefreshAt.formatted(date: .omitted, time: .shortened)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if hasQueuedBatchSubmissions {
                Text(
                    session.questions.isEmpty
                        ? "Queued scans are saved locally. Approve the rubric first, then tap Submit All Queued Scans."
                        : "Queued scans are ready. Tap Submit All Queued Scans to start grading."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteSubmission(submission)
                        } label: {
                            Label("Delete", systemImage: "trash")
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
        draftValidationMaxAttempts = session.validationMaxAttemptsResolved
        isEditingOverviewConfig = true
    }

    private func cancelOverviewConfigEditing() {
        isSavingOverviewConfig = false
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
        session.validationMaxAttempts = draftValidationMaxAttempts

        if !wasIntegerOnly && draftIntegerPointsOnly {
            normalizeSessionToIntegerPoints()
        }

        try? modelContext.save()
        isEditingOverviewConfig = false
        feedbackCenter.show("Session config saved.")
    }

    private func beginSaveOverviewConfig() {
        guard !isSavingOverviewConfig else { return }
        isSavingOverviewConfig = true
        saveOverviewConfigEdits()
        isSavingOverviewConfig = false
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

    private func handleCaptureCompletion(_ fileURLs: [URL], for flow: ActiveCaptureFlow) {
        activeCaptureFlow = nil

        switch flow.kind {
        case .master:
            pendingScanIntent = nil
            pendingScanSource = nil
            Task {
                await generateRubric(from: fileURLs)
            }
        case .student:
            pendingScanIntent = nil
            pendingScanSource = nil
            Task {
                await gradeSubmission(from: fileURLs)
            }
        case .batch:
            let pagesPerSubmission = pendingBatchPagesPerSubmission ?? session.maxPagesPerSubmission ?? 0
            pendingBatchPagesPerSubmission = nil
            pendingScanIntent = nil
            pendingScanSource = nil
            Task {
                await gradeSubmissionBatch(from: fileURLs, pagesPerSubmission: pagesPerSubmission)
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
    private func prepareSingleScanRequest(
        from fileURLs: [URL],
        preparingTitle: String
    ) async -> PreparedSingleScanRequest? {
        busyState = BusyOverlayState(title: preparingTitle, detail: "Optimizing captured pages")
        let pageData = await ScanImagePreparation.makeJPEGPageData(from: fileURLs) { completed, total in
            await MainActor.run {
                updateBusyPresentation(
                    title: preparingTitle,
                    detail: "Optimizing captured pages",
                    progressLabel: "Optimized \(completed) of \(total)",
                    progressValue: total == 0 ? nil : Double(completed) / Double(total)
                )
            }
        }
        guard !pageData.isEmpty else {
            busyState = nil
            alertItem = AlertItem(message: "The scan did not contain any pages.")
            return nil
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        return PreparedSingleScanRequest(apiKey: apiKey, pageData: pageData)
    }

    @MainActor
    private func generateRubric(from fileURLs: [URL]) async {
        defer { ScanCaptureStorage.removeFiles(at: fileURLs) }
        busyState = BusyOverlayState(title: "Preparing scan", detail: "Optimizing captured pages")
        let optimizedPageFileURLs = await ScanImagePreparation.makeOptimizedJPEGFiles(from: fileURLs) { completed, total in
            await MainActor.run {
                updateBusyPresentation(
                    title: "Preparing scan",
                    detail: "Optimizing captured pages",
                    progressLabel: "Optimized \(completed) of \(total)",
                    progressValue: total == 0 ? nil : Double(completed) / Double(total)
                )
            }
        }
        defer { ScanCaptureStorage.removeFiles(at: optimizedPageFileURLs) }

        guard !optimizedPageFileURLs.isEmpty else {
            busyState = nil
            alertItem = AlertItem(message: "The scan did not contain any pages.")
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        session.setMasterScans(from: optimizedPageFileURLs)
        session.setPendingRubricPayload(nil)
        session.clearRubricGenerationState()

        do {
            updateBusyPresentation(
                title: "Submitting answer key",
                detail: "Uploading the scan and waiting for the OpenAI batch id. Do not close the app until this step finishes."
            )

            let requestID = "answer-key-\(session.id.uuidString)-\(UUID().uuidString)"
            let creation = try await OpenAIService.shared.createAnswerKeyBatch(
                apiKey: apiKey,
                modelID: session.answerModelID,
                sessionTitle: session.title,
                submissions: [
                    OpenAIBatchAnswerKeyInput(
                        customID: requestID,
                        pageFileURLs: optimizedPageFileURLs
                    ),
                ],
                reasoningEffort: session.answerReasoningEffort,
                verbosity: session.answerVerbosity
            )

            session.markRubricGenerationPending(
                batchID: creation.batchID,
                requestID: requestID,
                detail: detailTextForBatchStatus(status: creation.status, requestCounts: nil)
            )
            try? modelContext.save()

            busyState = nil
            await AppNotificationCoordinator.shared.requestAuthorizationIfNeeded()
            feedbackCenter.show("Answer key submitted. HGrader will keep checking until it is ready.", tone: .info)
            await refreshPendingRubricGeneration(force: true)
        } catch {
            busyState = nil
            session.markRubricGenerationFailed(message: error.localizedDescription)
            try? modelContext.save()
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    @MainActor
    private func gradeSubmission(from fileURLs: [URL]) async {
        defer { ScanCaptureStorage.removeFiles(at: fileURLs) }
        guard let request = await prepareSingleScanRequest(from: fileURLs, preparingTitle: "Preparing submission") else { return }
        let pageData = request.pageData
        let apiKey = request.apiKey
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
                recordUsage(usage, apiKey: apiKey, persistChanges: false)
            }
            if !processed.usageSummaries.isEmpty {
                try? modelContext.save()
            }

            submissionDraft = processed.draft
        } catch {
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    @MainActor
    private func gradeSubmissionBatch(from fileURLs: [URL], pagesPerSubmission: Int) async {
        defer { ScanCaptureStorage.removeFiles(at: fileURLs) }
        busyState = BusyOverlayState(title: "Preparing batch job", detail: "Optimizing captured pages")
        let optimizedPageFileURLs = await ScanImagePreparation.makeOptimizedJPEGFiles(from: fileURLs) { completed, total in
            await MainActor.run {
                updateBusyPresentation(
                    title: "Preparing batch job",
                    detail: "Optimizing captured pages",
                    progressLabel: "Optimized \(completed) of \(total)",
                    progressValue: total == 0 ? nil : Double(completed) / Double(total)
                )
            }
        }
        defer { ScanCaptureStorage.removeFiles(at: optimizedPageFileURLs) }

        let pageGroups: [[URL]]
        do {
            pageGroups = try SubmissionBatchOrganizer.split(
                pages: optimizedPageFileURLs,
                pagesPerSubmission: pagesPerSubmission
            )
        } catch {
            alertItem = AlertItem(message: error.localizedDescription)
            return
        }

        defer { busyState = nil }

        if session.questions.isEmpty {
            let queuedSubmissions = createQueuedBatchSubmissions(for: pageGroups)
            selectedTab = .results
            feedbackCenter.show(
                "Added \(queuedSubmissions.count) student scan sets. They will stay queued until the rubric is approved.",
                tone: .info
            )
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        let placeholders = createPendingBatchSubmissions(for: pageGroups)

        do {
            updateBusyPresentation(
                title: "Submitting batch job",
                detail: "Uploading requests to OpenAI and waiting for the batch id. Do not close the app until this step finishes."
            )

            let batchInputs = zip(placeholders, pageGroups).compactMap { submission, pageData -> OpenAIBatchSubmissionInput? in
                guard let customID = submission.remoteBatchRequestID else { return nil }
                return OpenAIBatchSubmissionInput(
                    customID: customID,
                    pageFileURLs: pageData
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
            await AppNotificationCoordinator.shared.requestAuthorizationIfNeeded()

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
        session.setPendingRubricPayload(nil)
        session.clearRubricGenerationState()
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
        feedbackCenter.show("Rubric saved.")
    }

    private func openPendingRubricReview() {
        guard let payload = session.pendingRubricPayload() else { return }
        rubricReviewState = RubricReviewState
            .from(
                payload: payload,
                pageData: session.masterScans(),
                integerPointsOnly: session.integerPointsOnlyEnabled
            )
            .normalized(integerPointsOnly: session.integerPointsOnlyEnabled)
    }

    private func saveSubmission(_ approvedDraft: SubmissionDraft, persistChanges: Bool = true) {
        let trimmedName = approvedDraft.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let submission = StudentSubmission(
            studentName: trimmedName,
            nameNeedsReview: approvedDraft.nameNeedsReview,
            needsAttention: approvedDraft.needsAttention,
            attentionReasonsText: approvedDraft.attentionReasonsText.trimmingCharacters(in: .whitespacesAndNewlines),
            validationNeedsReview: false,
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
            feedbackCenter.show(trimmedName.isEmpty ? "Submission saved." : "Saved \(trimmedName).")
        }
    }

    private func updateSubmission(_ submission: StudentSubmission, with approvedDraft: SubmissionDraft) {
        let normalized = approvedDraft.normalized(integerPointsOnly: session.integerPointsOnlyEnabled)
        let trimmedName = normalized.studentName.trimmingCharacters(in: .whitespacesAndNewlines)

        submission.studentName = trimmedName
        submission.nameNeedsReview = normalized.nameNeedsReview
        submission.needsAttention = normalized.needsAttention
        submission.attentionReasonsText = normalized.attentionReasonsText.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.validationNeedsReview = normalized.validationNeedsReview
        submission.overallNotes = normalized.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.teacherReviewed = true
        submission.processingStateRaw = StudentSubmissionProcessingState.completed.rawValue
        submission.processingDetail = nil
        submission.setLatestValidationPayload(nil)
        submission.setQuestionGrades(normalized.grades)
        submission.clearBatchPipelineState()
        try? modelContext.save()
        feedbackCenter.show(trimmedName.isEmpty ? "Submission regraded." : "Regraded \(trimmedName).")
    }

    private func saveSubmissions(_ approvedDrafts: [SubmissionDraft]) {
        for draft in approvedDrafts {
            saveSubmission(draft.normalized(integerPointsOnly: session.integerPointsOnlyEnabled), persistChanges: false)
        }
        try? modelContext.save()
    }

    @MainActor
    private func regradeSubmission(_ submission: StudentSubmission) async {
        guard hasAPIKey else {
            alertItem = AlertItem(message: "Add your OpenAI API key in Settings before regrading.")
            return
        }

        let pageData = submission.scans()
        guard !pageData.isEmpty else {
            alertItem = AlertItem(message: "This submission no longer has saved scan pages to regrade.")
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        let processor = makeSubmissionProcessor(apiKey: apiKey)
        defer { busyState = nil }

        do {
            updateBusyPresentation(title: "Regrading submission", detail: "Sending saved pages for grading")

            let processed = try await processor.grade(
                pageData: pageData,
                requestNamespace: "saved-regrade-\(submission.id.uuidString)",
                requestLabelPrefix: submission.listDisplayName,
                progress: { stage in
                    await MainActor.run {
                        updateBusyPresentation(
                            title: "Regrading submission",
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
                recordUsage(usage, apiKey: apiKey, persistChanges: false)
            }
            if !processed.usageSummaries.isEmpty {
                try? modelContext.save()
            }

            submissionBeingRegraded = submission
            submissionDraft = processed.draft
        } catch {
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    @MainActor
    private func regradeAllSavedSubmissions() async {
        guard hasAPIKey else {
            alertItem = AlertItem(message: "Add your OpenAI API key in Settings before regrading.")
            return
        }
        guard !hasRefreshablePendingBatchSubmissions else {
            alertItem = AlertItem(message: "Wait for the current pending grading jobs to finish before starting a bulk regrade.")
            return
        }

        let eligibleSubmissions = session.submissions.filter { !$0.isProcessingPending }
        guard !eligibleSubmissions.isEmpty else {
            alertItem = AlertItem(message: "There are no saved submissions available to regrade.")
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        var batchEntries: [(submission: StudentSubmission, requestID: String, pageFileURLs: [URL])] = []
        var skippedCount = 0

        for submission in eligibleSubmissions {
            guard let pageFileURLs = ensureSubmissionScanFileURLs(for: submission), !pageFileURLs.isEmpty else {
                skippedCount += 1
                continue
            }

            batchEntries.append((
                submission: submission,
                requestID: "regradeall-\(submission.id.uuidString)-\(UUID().uuidString)",
                pageFileURLs: pageFileURLs
            ))
        }

        guard !batchEntries.isEmpty else {
            alertItem = AlertItem(message: "None of the saved submissions still have scan pages available for regrading.")
            return
        }

        do {
            updateBusyPresentation(
                title: "Submitting regrade batch",
                detail: "Uploading saved scans to OpenAI and waiting for the batch id. Do not close the app until this step finishes."
            )

            let creation = try await OpenAIService.shared.createSubmissionGradingBatch(
                apiKey: apiKey,
                modelID: session.gradingModelID,
                rubric: session.sortedQuestions.map(\.snapshot),
                overallRules: session.overallGradingRules,
                submissions: batchEntries.map {
                    OpenAIBatchSubmissionInput(
                        customID: $0.requestID,
                        pageFileURLs: $0.pageFileURLs
                    )
                },
                integerPointsOnly: session.integerPointsOnlyEnabled,
                relaxedGradingMode: session.relaxedGradingModeEnabled,
                reasoningEffort: session.gradingReasoningEffort,
                verbosity: session.gradingVerbosity
            )

            for entry in batchEntries {
                prepareSubmissionForBulkRegrade(
                    entry.submission,
                    requestID: entry.requestID,
                    batchID: creation.batchID,
                    batchStatus: creation.status
                )
            }

            try? modelContext.save()
            busyState = nil
            selectedTab = .results
            await AppNotificationCoordinator.shared.requestAuthorizationIfNeeded()

            let skippedMessage = skippedCount > 0 ? " \(skippedCount) skipped because scans were missing." : ""
            feedbackCenter.show(
                "Submitted \(batchEntries.count) saved submissions for regrading.\(skippedMessage)",
                tone: .info
            )
            await refreshPendingBatchSubmissions(force: true)
        } catch {
            busyState = nil
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    private func prepareSubmissionForBulkRegrade(
        _ submission: StudentSubmission,
        requestID: String,
        batchID: String,
        batchStatus: String
    ) {
        submission.processingStateRaw = StudentSubmissionProcessingState.pending.rawValue
        submission.batchStageRaw = StudentSubmissionBatchStage.grading.rawValue
        submission.batchAttemptNumber = 0
        submission.processingDetail = detailTextForBatchStatus(status: batchStatus, requestCounts: nil)
        submission.remoteBatchID = batchID
        submission.remoteBatchRequestID = requestID
        submission.teacherReviewed = false
        submission.validationNeedsReview = false
        submission.overallNotes = "Regrading requested."
        submission.setLatestSubmissionPayload(nil)
        submission.setLatestValidationPayload(nil)
        submission.setQuestionGrades([])
        submission.maxScore = session.totalPossiblePoints
    }

    @MainActor
    private func submitQueuedScansForGrading() async {
        guard hasAPIKey else {
            alertItem = AlertItem(message: "Add your OpenAI API key in Settings before submitting queued scans.")
            return
        }
        guard !session.questions.isEmpty else {
            alertItem = AlertItem(message: "Approve the rubric before submitting queued scans.")
            return
        }
        guard !hasRefreshablePendingBatchSubmissions else {
            alertItem = AlertItem(message: "Wait for the current pending grading jobs to finish before submitting queued scans.")
            return
        }

        let queuedSubmissions = session.submissions.filter(\.isQueuedForRubric)
        guard !queuedSubmissions.isEmpty else {
            alertItem = AlertItem(message: "There are no queued scans ready to submit.")
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        var batchEntries: [(submission: StudentSubmission, requestID: String, pageFileURLs: [URL])] = []
        var skippedCount = 0

        for submission in queuedSubmissions {
            guard let pageFileURLs = ensureSubmissionScanFileURLs(for: submission), !pageFileURLs.isEmpty else {
                skippedCount += 1
                markSubmissionFailed(submission, message: "Saved scan pages were missing, so this queued submission could not be submitted.")
                continue
            }

            batchEntries.append((
                submission: submission,
                requestID: "queued-\(submission.id.uuidString)-\(UUID().uuidString)",
                pageFileURLs: pageFileURLs
            ))
        }

        guard !batchEntries.isEmpty else {
            try? modelContext.save()
            alertItem = AlertItem(message: "None of the queued submissions still had scan pages available for submission.")
            return
        }

        do {
            updateBusyPresentation(
                title: "Submitting queued scans",
                detail: "Uploading the queued scans to OpenAI and waiting for the batch id. Do not close the app until this step finishes."
            )

            let creation = try await OpenAIService.shared.createSubmissionGradingBatch(
                apiKey: apiKey,
                modelID: session.gradingModelID,
                rubric: session.sortedQuestions.map(\.snapshot),
                overallRules: session.overallGradingRules,
                submissions: batchEntries.map {
                    OpenAIBatchSubmissionInput(
                        customID: $0.requestID,
                        pageFileURLs: $0.pageFileURLs
                    )
                },
                integerPointsOnly: session.integerPointsOnlyEnabled,
                relaxedGradingMode: session.relaxedGradingModeEnabled,
                reasoningEffort: session.gradingReasoningEffort,
                verbosity: session.gradingVerbosity
            )

            for entry in batchEntries {
                prepareSubmissionForBulkRegrade(
                    entry.submission,
                    requestID: entry.requestID,
                    batchID: creation.batchID,
                    batchStatus: creation.status
                )
                entry.submission.overallNotes = "Queued scans submitted for grading."
            }

            try? modelContext.save()
            busyState = nil
            selectedTab = .results
            await AppNotificationCoordinator.shared.requestAuthorizationIfNeeded()

            let skippedMessage = skippedCount > 0 ? " \(skippedCount) could not be submitted because scans were missing." : ""
            feedbackCenter.show(
                "Submitted \(batchEntries.count) queued scan sets for grading.\(skippedMessage)",
                tone: .info
            )
            await refreshPendingBatchSubmissions(force: true)
        } catch {
            busyState = nil
            alertItem = AlertItem(message: error.localizedDescription)
        }
    }

    private func createQueuedBatchSubmissions(for pageGroups: [[URL]]) -> [StudentSubmission] {
        let queuedSubmissions = pageGroups.enumerated().map { index, pageFileURLs in
            let submission = StudentSubmission(
                studentName: "Queued Submission \(index + 1)",
                nameNeedsReview: false,
                overallNotes: "Saved scan. Waiting for rubric approval before submission.",
                teacherReviewed: false,
                totalScore: 0,
                maxScore: session.totalPossiblePoints,
                processingStateRaw: StudentSubmissionProcessingState.pending.rawValue,
                batchStageRaw: StudentSubmissionBatchStage.queued.rawValue,
                batchAttemptNumber: nil,
                processingDetail: "Saved scan. Waiting for rubric approval before submission.",
                session: session
            )
            submission.setScans(from: pageFileURLs)
            modelContext.insert(submission)
            session.submissions.append(submission)
            return submission
        }

        try? modelContext.save()
        return queuedSubmissions
    }

    private func createPendingBatchSubmissions(for pageGroups: [[URL]]) -> [StudentSubmission] {
        let placeholders = pageGroups.enumerated().map { index, pageFileURLs in
            let submission = StudentSubmission(
                studentName: "Pending Submission \(index + 1)",
                nameNeedsReview: false,
                needsAttention: false,
                overallNotes: "OpenAI batch job submitted. Result pending.",
                teacherReviewed: false,
                totalScore: 0,
                maxScore: session.totalPossiblePoints,
                processingStateRaw: StudentSubmissionProcessingState.pending.rawValue,
                batchStageRaw: StudentSubmissionBatchStage.grading.rawValue,
                batchAttemptNumber: 0,
                processingDetail: "Preparing batch submission",
                remoteBatchRequestID: "submission-\(UUID().uuidString)",
                session: session
            )
            submission.setScans(from: pageFileURLs)
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

    private func deleteSubmission(_ submission: StudentSubmission) {
        if let index = session.submissions.firstIndex(where: { $0.id == submission.id }) {
            session.submissions.remove(at: index)
        }
        modelContext.delete(submission)
        try? modelContext.save()
        feedbackCenter.show("Result deleted.", tone: .info)
    }

    @MainActor
    private func refreshPendingRubricGeneration(force: Bool) async {
        guard session.hasPendingRubricGeneration else { return }
        guard !isRefreshingPendingRubric else { return }
        guard hasAPIKey else { return }

        if
            !force,
            let lastPendingRubricRefreshAt,
            Date.now.timeIntervalSince(lastPendingRubricRefreshAt) < 12
        {
            return
        }

        guard
            let batchID = session.rubricRemoteBatchID,
            let requestID = session.rubricRemoteBatchRequestID
        else {
            session.markRubricGenerationFailed(message: "The saved answer key request is missing its batch metadata.")
            try? modelContext.save()
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        isRefreshingPendingRubric = true
        lastPendingRubricRefreshAt = .now
        defer { isRefreshingPendingRubric = false }

        do {
            let snapshot = try await OpenAIService.shared.fetchBatchStatus(
                apiKey: apiKey,
                batchID: batchID
            )

            switch snapshot.status {
            case "completed":
                try await finalizeCompletedRubricBatch(
                    snapshot,
                    requestID: requestID,
                    apiKey: apiKey
                )
            case "failed", "expired", "cancelled":
                let message = snapshot.errors.first ?? detailTextForBatchStatus(
                    status: snapshot.status,
                    requestCounts: snapshot.requestCounts
                )
                session.markRubricGenerationFailed(message: message)
            default:
                session.rubricProcessingDetail = detailTextForBatchStatus(
                    status: snapshot.status,
                    requestCounts: snapshot.requestCounts
                )
            }
        } catch {
            session.rubricProcessingDetail = "Unable to refresh answer key status. \(error.localizedDescription)"
        }

        try? modelContext.save()
    }

    @MainActor
    private func finalizeCompletedRubricBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        requestID: String,
        apiKey: String
    ) async throws {
        let results = try await fetchAnswerKeyBatchResults(snapshot: snapshot, apiKey: apiKey)
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let result = results.first { $0.customID == requestID }
        let errorMessage = errors.first { $0.customID == requestID }?.message

        if let result {
            recordUsage(result.usage, apiKey: apiKey)

            guard !result.payload.questions.isEmpty else {
                session.markRubricGenerationFailed(
                    message: "The model did not return any gradeable questions. Try rescanning the blank assignment."
                )
                return
            }

            session.setPendingRubricPayload(result.payload)
            session.clearRubricGenerationState()
            try? modelContext.save()

            openPendingRubricReview()
            await AppNotificationCoordinator.shared.notifyAnswerKeyReady(sessionTitle: session.title)
            feedbackCenter.show("Answer key ready for review.", tone: .info)
        } else if let errorMessage {
            session.markRubricGenerationFailed(message: errorMessage)
        } else {
            session.markRubricGenerationFailed(
                message: "OpenAI completed the answer key batch but did not return a result."
            )
        }
    }

    @MainActor
    private func refreshPendingBatchSubmissions(force: Bool) async {
        guard hasRefreshablePendingBatchSubmissions else { return }
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
        let batchIDs = Array(Set(session.submissions.compactMap { submission in
            submission.hasRemoteBatchInFlight ? submission.remoteBatchID : nil
        }))

        let summaryBeforeRefresh = batchRefreshSummary
        isRefreshingPendingBatches = true
        lastPendingBatchRefreshAt = .now
        defer { isRefreshingPendingBatches = false }

        for batchID in batchIDs {
            do {
                let snapshot = try await OpenAIService.shared.fetchBatchStatus(
                    apiKey: apiKey,
                    batchID: batchID
                )
                storeBatchStatusDebug(snapshot, batchID: batchID)
                try await applyBatchStatusSnapshot(snapshot, apiKey: apiKey)
            } catch {
                markBatchSubmissions(
                    batchID: batchID,
                    detail: "Unable to refresh batch status. \(error.localizedDescription)"
                )
            }
        }

        if !hasActivePendingBatchRequests {
            do {
                try await submitQueuedBatchPipelineStages(apiKey: apiKey)
            } catch {
                for submission in session.submissions where submission.isProcessingPending && !submission.hasRemoteBatchInFlight {
                    submission.processingDetail = "Automatic batch submission failed. \(error.localizedDescription)"
                }
            }
        }

        try? modelContext.save()

        let summaryAfterRefresh = batchRefreshSummary
        if summaryBeforeRefresh.pending > 0 && summaryAfterRefresh.pending == 0 {
            await AppNotificationCoordinator.shared.notifyBatchGradingFinished(
                sessionTitle: session.title,
                completed: summaryAfterRefresh.completed,
                failed: summaryAfterRefresh.failed
            )
        }

        if force {
            feedbackCenter.show(batchRefreshFeedbackMessage(before: summaryBeforeRefresh, after: summaryAfterRefresh), tone: .info)
        }
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
        let pendingSubmissions = session.submissions.filter {
            $0.isProcessingPending && $0.remoteBatchID == snapshot.batchID
        }
        guard !pendingSubmissions.isEmpty else { return }

        switch pendingSubmissions.compactMap(\.batchStage).first ?? .grading {
        case .queued:
            return
        case .grading:
            try await finalizeCompletedGradingBatch(snapshot, pendingSubmissions: pendingSubmissions, apiKey: apiKey)
        case .validating:
            try await finalizeCompletedValidationBatch(snapshot, pendingSubmissions: pendingSubmissions, apiKey: apiKey)
        case .regrading:
            try await finalizeCompletedRegradingBatch(snapshot, pendingSubmissions: pendingSubmissions, apiKey: apiKey)
        }
    }

    @MainActor
    private func finalizeCompletedGradingBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let results = try await fetchSubmissionBatchResults(snapshot: snapshot, modelID: session.gradingModelID, apiKey: apiKey)
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                markSubmissionFailed(submission, message: "This batch submission is missing its request identifier.")
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, apiKey: apiKey, persistChanges: false)
                submission.setLatestSubmissionPayload(result.payload)
                submission.setLatestValidationPayload(nil)
                submission.updateDebugInfo { info in
                    info.latestBatchOutputLineJSON = result.rawLineJSON
                    info.latestBatchErrorLineJSON = nil
                    info.latestLookupSummary = nil
                }

                if session.validationEnabledResolved {
                    queueSubmissionForBatchStage(
                        submission,
                        stage: .validating,
                        attempt: 1,
                        detail: "Queued for validation pass 1."
                    )
                } else {
                    completeSubmission(
                        submission,
                        from: result.payload,
                        validationNeedsReview: false,
                        reviewMessage: nil
                    )
                }
            } else if let error = errors.first(where: { $0.customID == requestID }) {
                markSubmissionFailed(submission, message: error.message)
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                markSubmissionFailed(
                    submission,
                    message: "OpenAI completed the batch but did not return a result for this submission."
                )
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = missingBatchResultSummary(
                        requestID: requestID,
                        results: results.map(\.customID),
                        errors: errors.map(\.customID)
                    )
                }
            }
        }
    }

    @MainActor
    private func finalizeCompletedValidationBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let validationModelID = session.validationModelIDResolved
        let results = try await fetchValidationBatchResults(snapshot: snapshot, modelID: validationModelID, apiKey: apiKey)
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "This validation batch submission is missing its request identifier."
                )
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, apiKey: apiKey, persistChanges: false)
                submission.setLatestValidationPayload(result.payload)
                submission.updateDebugInfo { info in
                    info.latestBatchOutputLineJSON = result.rawLineJSON
                    info.latestBatchErrorLineJSON = nil
                    info.latestLookupSummary = nil
                }

                if result.payload.isGradingCorrect {
                    guard let payload = submission.latestSubmissionPayload() else {
                        markSubmissionFailed(
                            submission,
                            message: "Validation completed but the latest grading payload was missing."
                        )
                        continue
                    }
                    completeSubmission(
                        submission,
                        from: payload,
                        validationNeedsReview: false,
                        reviewMessage: nil
                    )
                } else if submission.currentBatchAttemptNumber >= session.validationMaxAttemptsResolved {
                    let validationAttemptLabel = session.validationMaxAttemptsResolved == 1
                        ? "1 validation attempt"
                        : "\(session.validationMaxAttemptsResolved) validation attempts"
                    finalizeSubmissionWithValidationReview(
                        submission,
                        message: "Automated validation could not fully confirm this grading after \(validationAttemptLabel)."
                    )
                } else {
                    queueSubmissionForBatchStage(
                        submission,
                        stage: .regrading,
                        attempt: submission.currentBatchAttemptNumber,
                        detail: "Queued for regrade pass \(submission.currentBatchAttemptNumber) after validation pass \(submission.currentBatchAttemptNumber)."
                    )
                }
            } else if let error = errors.first(where: { $0.customID == requestID }) {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "Validation batch could not finish automatically. \(error.message)"
                )
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "OpenAI completed the validation batch but did not return a result for this submission."
                )
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = missingBatchResultSummary(
                        requestID: requestID,
                        results: results.map(\.customID),
                        errors: errors.map(\.customID)
                    )
                }
            }
        }
    }

    @MainActor
    private func finalizeCompletedRegradingBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let results = try await fetchSubmissionBatchResults(snapshot: snapshot, modelID: session.gradingModelID, apiKey: apiKey)
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "This regrade batch submission is missing its request identifier."
                )
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, apiKey: apiKey, persistChanges: false)
                submission.setLatestSubmissionPayload(result.payload)
                submission.setLatestValidationPayload(nil)
                submission.updateDebugInfo { info in
                    info.latestBatchOutputLineJSON = result.rawLineJSON
                    info.latestBatchErrorLineJSON = nil
                    info.latestLookupSummary = nil
                }
                queueSubmissionForBatchStage(
                    submission,
                    stage: .validating,
                    attempt: submission.currentBatchAttemptNumber + 1,
                    detail: "Queued for validation pass \(submission.currentBatchAttemptNumber + 1)."
                )
            } else if let error = errors.first(where: { $0.customID == requestID }) {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "Regrade batch could not finish automatically. \(error.message)"
                )
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "OpenAI completed the regrade batch but did not return a result for this submission."
                )
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = missingBatchResultSummary(
                        requestID: requestID,
                        results: results.map(\.customID),
                        errors: errors.map(\.customID)
                    )
                }
            }
        }
    }

    private func fetchSubmissionBatchResults(
        snapshot: OpenAIBatchStatusSnapshot,
        modelID: String,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionResult<SubmissionPayload>] {
        guard let outputFileID = snapshot.outputFileID else { return [] }
        return try await OpenAIService.shared.fetchSubmissionBatchResults(
            apiKey: apiKey,
            modelID: modelID,
            outputFileID: outputFileID
        )
    }

    private func fetchAnswerKeyBatchResults(
        snapshot: OpenAIBatchStatusSnapshot,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionResult<MasterExamPayload>] {
        guard let outputFileID = snapshot.outputFileID else { return [] }
        return try await OpenAIService.shared.fetchAnswerKeyBatchResults(
            apiKey: apiKey,
            modelID: session.answerModelID,
            outputFileID: outputFileID
        )
    }

    private func fetchValidationBatchResults(
        snapshot: OpenAIBatchStatusSnapshot,
        modelID: String,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionResult<GradingValidationPayload>] {
        guard let outputFileID = snapshot.outputFileID else { return [] }
        return try await OpenAIService.shared.fetchValidationBatchResults(
            apiKey: apiKey,
            modelID: modelID,
            outputFileID: outputFileID
        )
    }

    private func fetchBatchErrors(
        snapshot: OpenAIBatchStatusSnapshot,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionError] {
        guard let errorFileID = snapshot.errorFileID else { return [] }
        return try await OpenAIService.shared.fetchBatchErrors(
            apiKey: apiKey,
            errorFileID: errorFileID
        )
    }

    private func submitQueuedBatchPipelineStages(apiKey: String) async throws {
        try await submitQueuedValidationBatch(apiKey: apiKey)
        try await submitQueuedRegradingBatch(apiKey: apiKey)
    }

    private func submitQueuedValidationBatch(apiKey: String) async throws {
        let queued = session.submissions.filter {
            $0.isProcessingPending && !$0.hasRemoteBatchInFlight && $0.batchStage == .validating
        }
        guard !queued.isEmpty else { return }

        let inputs = queued.compactMap { submission -> OpenAIBatchValidationInput? in
            guard
                let pageFileURLs = ensureSubmissionScanFileURLs(for: submission),
                let payload = submission.latestSubmissionPayload()
            else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "Validation batch could not be created because the saved grading payload or page scans were missing."
                )
                return nil
            }
            let requestID = "validate-\(submission.id.uuidString)-\(UUID().uuidString)"
            submission.remoteBatchRequestID = requestID
            return OpenAIBatchValidationInput(
                customID: requestID,
                pageFileURLs: pageFileURLs,
                candidateGrading: payload
            )
        }
        guard !inputs.isEmpty else { return }

        let creation = try await OpenAIService.shared.createSubmissionValidationBatch(
            apiKey: apiKey,
            modelID: session.validationModelIDResolved,
            rubric: session.sortedQuestions.map(\.snapshot),
            overallRules: session.overallGradingRules,
            submissions: inputs,
            integerPointsOnly: session.integerPointsOnlyEnabled,
            relaxedGradingMode: session.relaxedGradingModeEnabled,
            reasoningEffort: session.validationReasoningEffort,
            verbosity: session.validationVerbosity
        )

        for submission in queued where submission.remoteBatchRequestID != nil {
            submission.remoteBatchID = creation.batchID
            submission.processingDetail = "Validation pass \(submission.currentBatchAttemptNumber) batch submitted. \(detailTextForBatchStatus(status: creation.status, requestCounts: nil))"
        }
    }

    private func submitQueuedRegradingBatch(apiKey: String) async throws {
        let queued = session.submissions.filter {
            $0.isProcessingPending && !$0.hasRemoteBatchInFlight && $0.batchStage == .regrading
        }
        guard !queued.isEmpty else { return }

        let inputs = queued.compactMap { submission -> OpenAIBatchRegradeInput? in
            guard
                let pageFileURLs = ensureSubmissionScanFileURLs(for: submission),
                let latestPayload = submission.latestSubmissionPayload(),
                let validationPayload = submission.latestValidationPayload()
            else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "Regrade batch could not be created because the saved grading or validation context was missing."
                )
                return nil
            }
            let requestID = "regrade-\(submission.id.uuidString)-\(UUID().uuidString)"
            submission.remoteBatchRequestID = requestID
            return OpenAIBatchRegradeInput(
                customID: requestID,
                pageFileURLs: pageFileURLs,
                previousGrading: latestPayload,
                validatorFeedback: validationPayload
            )
        }
        guard !inputs.isEmpty else { return }

        let creation = try await OpenAIService.shared.createSubmissionRegradingBatch(
            apiKey: apiKey,
            modelID: session.gradingModelID,
            rubric: session.sortedQuestions.map(\.snapshot),
            overallRules: session.overallGradingRules,
            submissions: inputs,
            integerPointsOnly: session.integerPointsOnlyEnabled,
            relaxedGradingMode: session.relaxedGradingModeEnabled,
            reasoningEffort: session.gradingReasoningEffort,
            verbosity: session.gradingVerbosity
        )

        for submission in queued where submission.remoteBatchRequestID != nil {
            submission.remoteBatchID = creation.batchID
            submission.processingDetail = "Regrade pass \(submission.currentBatchAttemptNumber) batch submitted. \(detailTextForBatchStatus(status: creation.status, requestCounts: nil))"
        }
    }

    private func queueSubmissionForBatchStage(
        _ submission: StudentSubmission,
        stage: StudentSubmissionBatchStage,
        attempt: Int,
        detail: String
    ) {
        submission.processingStateRaw = StudentSubmissionProcessingState.pending.rawValue
        submission.batchStageRaw = stage.rawValue
        submission.batchAttemptNumber = attempt
        submission.remoteBatchID = nil
        submission.remoteBatchRequestID = nil
        submission.processingDetail = detail
    }

    private func completeSubmission(
        _ submission: StudentSubmission,
        from payload: SubmissionPayload,
        validationNeedsReview: Bool,
        reviewMessage: String?
    ) {
        var draft = SubmissionDraft.from(
            payload: payload,
            rubricSnapshots: session.sortedQuestions.map(\.snapshot),
            pageData: submission.scans(),
            integerPointsOnly: session.integerPointsOnlyEnabled
        )
        .normalized(integerPointsOnly: session.integerPointsOnlyEnabled)

        if validationNeedsReview {
            draft.validationNeedsReview = true
            draft.overallNotes = [
                reviewMessage,
                Optional(draft.overallNotes),
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        }

        submission.studentName = draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.nameNeedsReview = draft.nameNeedsReview
        submission.needsAttention = draft.needsAttention
        submission.attentionReasonsText = draft.attentionReasonsText.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.validationNeedsReview = draft.validationNeedsReview
        submission.overallNotes = draft.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.teacherReviewed = false
        submission.processingStateRaw = StudentSubmissionProcessingState.completed.rawValue
        submission.processingDetail = nil
        submission.setQuestionGrades(draft.grades)
        submission.clearBatchPipelineState()
    }

    private func finalizeSubmissionWithValidationReview(
        _ submission: StudentSubmission,
        message: String
    ) {
        if let payload = submission.latestSubmissionPayload() {
            completeSubmission(
                submission,
                from: payload,
                validationNeedsReview: true,
                reviewMessage: message
            )
        } else {
            markSubmissionFailed(submission, message: message)
        }
    }

    private func ensureSubmissionScanFileURLs(for submission: StudentSubmission) -> [URL]? {
        if let existing = submission.scanFileURLs(), !existing.isEmpty {
            return existing
        }
        let pages = submission.scans()
        guard !pages.isEmpty else { return nil }
        submission.setScans(pages)
        return submission.scanFileURLs()
    }

    private func markBatchSubmissions(batchID: String, detail: String) {
        for submission in session.submissions where submission.isProcessingPending && submission.remoteBatchID == batchID {
            submission.processingDetail = stagePrefixedDetail(for: submission, detail: detail)
        }
    }

    private func markBatchSubmissionsAsFailed(batchID: String, message: String) {
        for submission in session.submissions where submission.isProcessingPending && submission.remoteBatchID == batchID {
            markSubmissionFailed(submission, message: message)
        }
    }

    private func markSubmissionFailed(_ submission: StudentSubmission, message: String) {
        submission.processingStateRaw = StudentSubmissionProcessingState.failed.rawValue
        submission.batchStageRaw = nil
        submission.batchAttemptNumber = nil
        submission.remoteBatchID = nil
        submission.remoteBatchRequestID = nil
        submission.processingDetail = message
        submission.overallNotes = message
        submission.teacherReviewed = false
        submission.needsAttention = false
        submission.attentionReasonsText = nil
        submission.validationNeedsReview = false
        submission.setLatestSubmissionPayload(nil)
        submission.setLatestValidationPayload(nil)
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
            return "OpenAI is processing the batch.\(countSuffix)"
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

    private func stagePrefixedDetail(for submission: StudentSubmission, detail: String) -> String {
        let prefix: String?
        switch submission.batchStage {
        case .queued:
            prefix = "Queued until rubric approval."
        case .grading:
            prefix = "Initial grading."
        case .validating:
            prefix = "Validation pass \(submission.currentBatchAttemptNumber)."
        case .regrading:
            prefix = "Regrade pass \(submission.currentBatchAttemptNumber)."
        case nil:
            prefix = nil
        }

        return [prefix, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func storeBatchStatusDebug(_ snapshot: OpenAIBatchStatusSnapshot, batchID: String) {
        guard
            let data = try? JSONEncoder.prettyPrinted.encode(snapshot),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        for submission in session.submissions where submission.remoteBatchID == batchID {
            submission.updateDebugInfo { info in
                info.batchStatusJSON = text
            }
        }
    }

    private func missingBatchResultSummary(
        requestID: String,
        results: [String],
        errors: [String]
    ) -> String {
        let resultsText = results.isEmpty ? "(none)" : results.joined(separator: ", ")
        let errorsText = errors.isEmpty ? "(none)" : errors.joined(separator: ", ")
        return """
        No matching batch line was found for request id:
        \(requestID)

        Result custom_ids:
        \(resultsText)

        Error custom_ids:
        \(errorsText)
        """
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

    private func recordUsage(_ usage: OpenAIUsageSummary?, apiKey: String, persistChanges: Bool = true) {
        guard let usage else { return }

        session.estimatedCostUSD = (session.estimatedCostUSD ?? 0) + usage.estimatedCostUSD
        if session.apiKeyFingerprint == nil {
            session.apiKeyFingerprint = APIKeyIdentity.fingerprint(for: apiKey)
        }
        if persistChanges {
            try? modelContext.save()
        }
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
    private func updateBusyPresentation(
        title: String,
        detail: String? = nil,
        progressLabel: String? = nil,
        progressValue: Double? = nil
    ) {
        updateBusyState { state in
            state.setPresentation(
                title: title,
                detail: detail,
                progressLabel: progressLabel,
                progressValue: progressValue
            )
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
                validationServiceTier: session.validationServiceTier,
                validationMaxAttempts: session.validationMaxAttemptsResolved
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
        feedbackCenter.show("Session deleted.", tone: .info)
        dismiss()
    }

    private var hasQueuedBatchSubmissions: Bool {
        session.submissions.contains(where: \.isQueuedForRubric)
    }

    private var hasRefreshablePendingBatchSubmissions: Bool {
        session.submissions.contains(where: \.isAwaitingRemoteProcessing)
    }

    private var pendingRubricPollingID: String {
        session.hasPendingRubricGeneration ? (session.rubricRemoteBatchID ?? "") : ""
    }

    private var hasActivePendingBatchRequests: Bool {
        session.submissions.contains(where: \.hasRemoteBatchInFlight)
    }

    private var filteredSubmissions: [StudentSubmission] {
        let trimmed = resultsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedSubmissions = session.sortedSubmissions
        guard !trimmed.isEmpty else { return sortedSubmissions }
        return sortedSubmissions.filter {
            $0.listDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var completedSubmissions: [StudentSubmission] {
        session.submissions.filter(\.isProcessingCompleted)
    }

    private var overallAverageScore: Double? {
        guard !completedSubmissions.isEmpty else { return nil }
        let total = completedSubmissions.reduce(0) { $0 + $1.totalScore }
        return total / Double(completedSubmissions.count)
    }

    private var overallAveragePercentage: Double? {
        guard let overallAverageScore, session.totalPossiblePoints > 0 else { return nil }
        return overallAverageScore / session.totalPossiblePoints
    }

    private func averageScore(for question: QuestionRubric) -> Double? {
        let scores = completedSubmissions.compactMap { submission -> Double? in
            submission.questionGrades().first(where: { $0.questionID == question.questionID })?.awardedPoints
        }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private func summaryColor(for percentage: Double) -> Color {
        switch percentage {
        case ..<0.5:
            return .red
        case ..<0.8:
            return .orange
        default:
            return .green
        }
    }

    private var batchRefreshSummary: BatchRefreshSummary {
        BatchRefreshSummary(
            pending: session.submissions.filter { $0.isAwaitingRemoteProcessing }.count,
            completed: session.submissions.filter { $0.isProcessingCompleted }.count,
            failed: session.submissions.filter { $0.isProcessingFailed }.count
        )
    }

    private func batchRefreshFeedbackMessage(
        before: BatchRefreshSummary,
        after: BatchRefreshSummary
    ) -> String {
        let completedDelta = max(after.completed - before.completed, 0)
        let failedDelta = max(after.failed - before.failed, 0)

        if completedDelta == 0 && failedDelta == 0 {
            return "Checked pending jobs. No new updates yet."
        }

        var parts: [String] = []
        if completedDelta > 0 {
            parts.append("\(completedDelta) completed")
        }
        if failedDelta > 0 {
            parts.append("\(failedDelta) failed")
        }
        parts.append("\(after.pending) still pending")
        return "Batch refresh finished: \(parts.joined(separator: ", "))."
    }
}

private struct BatchRefreshSummary {
    let pending: Int
    let completed: Int
    let failed: Int
}
