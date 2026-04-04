import SwiftUI
import SwiftData
import UIKit
import VisionKit
import ImageIO
import UniformTypeIdentifiers

enum ScanImagePreparation {
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

enum SessionSectionTab: String, CaseIterable, Identifiable {
    case rubric = "Rubric"
    case overview = "Overview"
    case results = "Results"

    var id: String { rawValue }
}

enum ScanIntent: Equatable {
    case master
    case student
    case batch
}

struct ActiveCaptureFlow: Identifiable, Equatable {
    let kind: ScanIntent
    let source: ScanCaptureSource

    var id: String {
        "\(source.rawValue)-\(String(describing: kind))"
    }
}

struct PreparedSingleScanRequest {
    let apiKey: String
    let pageData: [Data]
}

@MainActor
struct SessionDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    @EnvironmentObject var feedbackCenter: FeedbackCenter
    @Bindable var session: GradingSession

    @State var showingScanSourcePicker = false
    @State var showingBatchScanSetup = false
    @State var pendingScanIntent: ScanIntent?
    @State var pendingScanSource: ScanCaptureSource?
    @State var activeCaptureFlow: ActiveCaptureFlow?
    @State var queuedCaptureFlow: ActiveCaptureFlow?
    @State var selectedTab: SessionSectionTab = .overview
    @State var resultsSearchText = ""
    @State var rubricReviewState: RubricReviewState?
    @State var submissionDraft: SubmissionDraft?
    @State var selectedSubmission: StudentSubmission?
    @State var shareItem: ShareItem?
    @State var alertItem: AlertItem?
    @State var busyState: BusyOverlayState?
    @State var preparingState: BusyOverlayState?
    @State var showingDeleteConfirmation = false
    @State var showingRegradeAllConfirmation = false
    @State var pendingBatchPagesPerSubmission: Int?
    @State var isEditingOverviewConfig = false
    @State var draftAnswerModelID = ""
    @State var draftGradingModelID = ""
    @State var draftValidationModelID = ""
    @State var draftValidationEnabled = true
    @State var draftIntegerPointsOnly = false
    @State var draftRelaxedGradingMode = false
    @State var draftSessionEnded = false
    @State var draftAnswerReasoningEffort: String? = nil
    @State var draftGradingReasoningEffort: String? = nil
    @State var draftValidationReasoningEffort: String? = nil
    @State var draftAnswerVerbosity: String? = nil
    @State var draftGradingVerbosity: String? = nil
    @State var draftValidationVerbosity: String? = nil
    @State var draftAnswerServiceTier: String? = nil
    @State var draftGradingServiceTier: String? = nil
    @State var draftValidationServiceTier: String? = nil
    @State var draftValidationMaxAttempts = 2
    @State var isSavingOverviewConfig = false
    @State var isRefreshingPendingRubric = false
    @State var lastPendingRubricRefreshAt: Date?
    @State var isRefreshingPendingBatches = false
    @State var lastPendingBatchRefreshAt: Date?
    @State var submissionBeingRegraded: StudentSubmission?

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
                .refreshable {
                    await refreshAllJobStatuses(force: true)
                }
                .tag(SessionSectionTab.rubric)

                Form {
                    overviewSections
                }
                .refreshable {
                    await refreshAllJobStatuses(force: true)
                }
                .tag(SessionSectionTab.overview)

                Form {
                    resultsSections
                }
                .refreshable {
                    await refreshAllJobStatuses(force: true)
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
        .task(id: pendingBatchPollingID) {
            guard !pendingBatchPollingID.isEmpty else { return }
            while !Task.isCancelled && hasRefreshablePendingBatchSubmissions {
                await refreshPendingBatchSubmissions(force: false)
                guard hasRefreshablePendingBatchSubmissions else { break }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
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
}
