import SwiftUI
import SwiftData
import VisionKit

extension SessionDetailView {
    var hasAPIKey: Bool {
        let key = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSaveOverviewConfig: Bool {
        !draftAnswerModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draftGradingModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!draftValidationEnabled || !draftValidationModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func beginOverviewConfigEditing() {
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

    func cancelOverviewConfigEditing() {
        isSavingOverviewConfig = false
        isEditingOverviewConfig = false
    }

    func saveOverviewConfigEdits() {
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

    func beginSaveOverviewConfig() {
        guard !isSavingOverviewConfig else { return }
        isSavingOverviewConfig = true
        saveOverviewConfigEdits()
        isSavingOverviewConfig = false
    }

    func startMasterScan() {
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

    func startStudentScan() {
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

    func startBatchStudentScan() {
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

    var canStartAnyCapture: Bool {
        VNDocumentCameraViewController.isSupported || CameraCaptureViewController.isCaptureAvailable
    }

    func selectScanSource(_ source: ScanCaptureSource) {
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

    func presentCaptureFlow(kind: ScanIntent, source: ScanCaptureSource) {
        activeCaptureFlow = ActiveCaptureFlow(kind: kind, source: source)
    }

    func handleCaptureCompletion(_ fileURLs: [URL], for flow: ActiveCaptureFlow) {
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

    func handleCaptureCancellation(for flow: ActiveCaptureFlow) {
        activeCaptureFlow = nil
        if flow.kind == .batch {
            pendingBatchPagesPerSubmission = nil
        }
        pendingScanIntent = nil
        pendingScanSource = nil
        clearPreparingOverlay()
    }

    func handleCaptureError(_ error: Error, for flow: ActiveCaptureFlow) {
        handleCaptureCancellation(for: flow)
        alertItem = AlertItem(message: error.localizedDescription)
    }

    @MainActor
    func prepareSingleScanRequest(
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
    func generateRubric(from fileURLs: [URL]) async {
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
    func gradeSubmission(from fileURLs: [URL]) async {
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
    func gradeSubmissionBatch(from fileURLs: [URL], pagesPerSubmission: Int) async {
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

    func saveRubric(overallRules: String, approvedDrafts: [RubricQuestionDraft], pageData: [Data]) {
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

    func openPendingRubricReview() {
        guard let payload = session.pendingRubricPayload() else { return }
        rubricReviewState = RubricReviewState
            .from(
                payload: payload,
                pageData: session.masterScans(),
                integerPointsOnly: session.integerPointsOnlyEnabled
            )
            .normalized(integerPointsOnly: session.integerPointsOnlyEnabled)
    }

    func saveSubmission(_ approvedDraft: SubmissionDraft, persistChanges: Bool = true) {
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
        submission.setDebugInfo(approvedDraft.debugInfo)
        modelContext.insert(submission)
        session.submissions.append(submission)
        if persistChanges {
            try? modelContext.save()
            feedbackCenter.show(trimmedName.isEmpty ? "Submission saved." : "Saved \(trimmedName).")
        }
    }

    func updateSubmission(_ submission: StudentSubmission, with approvedDraft: SubmissionDraft) {
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
        submission.setDebugInfo(normalized.debugInfo)
        submission.clearBatchPipelineState()
        try? modelContext.save()
        feedbackCenter.show(trimmedName.isEmpty ? "Submission regraded." : "Regraded \(trimmedName).")
    }

    func saveSubmissions(_ approvedDrafts: [SubmissionDraft]) {
        for draft in approvedDrafts {
            saveSubmission(draft.normalized(integerPointsOnly: session.integerPointsOnlyEnabled), persistChanges: false)
        }
        try? modelContext.save()
    }

    @MainActor
    func regradeSubmission(_ submission: StudentSubmission) async {
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
    func regradeAllSavedSubmissions() async {
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

    func prepareSubmissionForBulkRegrade(
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
        submission.appendDebugTraceEntry(
            traceID: "pipeline-\(submission.id.uuidString)",
            traceTitle: "Pipeline",
            entryTitle: "Submitted",
            body: "Submitted initial grading batch request \(requestID) in batch \(batchID). \(detailTextForBatchStatus(status: batchStatus, requestCounts: nil))",
            kind: .outgoing,
            mergeConsecutiveDuplicates: false
        )
    }

    @MainActor
    func submitQueuedScansForGrading() async {
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

    func createQueuedBatchSubmissions(for pageGroups: [[URL]]) -> [StudentSubmission] {
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

    func createPendingBatchSubmissions(for pageGroups: [[URL]]) -> [StudentSubmission] {
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

    func removePendingBatchSubmissions(_ submissions: [StudentSubmission]) {
        for submission in submissions {
            if let index = session.submissions.firstIndex(where: { $0.id == submission.id }) {
                session.submissions.remove(at: index)
            }
            modelContext.delete(submission)
        }
        try? modelContext.save()
    }

    func deleteSubmission(_ submission: StudentSubmission) {
        if let index = session.submissions.firstIndex(where: { $0.id == submission.id }) {
            session.submissions.remove(at: index)
        }
        modelContext.delete(submission)
        try? modelContext.save()
        feedbackCenter.show("Result deleted.", tone: .info)
    }
}
