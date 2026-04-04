import SwiftUI
import SwiftData

extension SessionDetailView {
    @MainActor
    func exportCSV() async {
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
    func exportPackage() async {
        showPreparingOverlay(title: "Preparing full export", detail: "Building ZIP archive")
        defer { clearPreparingOverlay() }
        await Task.yield()

        do {
            shareItem = ShareItem(url: try SessionExporter.temporaryPackageURL(for: session))
        } catch {
            alertItem = AlertItem(message: "Unable to export the full session package. \(error.localizedDescription)")
        }
    }

    func recordUsage(_ usage: OpenAIUsageSummary?, apiKey: String, persistChanges: Bool = true) {
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
    func updateBusyState(_ mutate: (inout BusyOverlayState) -> Void) {
        var state = busyState ?? BusyOverlayState(title: "Working")
        mutate(&state)
        busyState = state
    }

    @MainActor
    func showPreparingOverlay(title: String, detail: String? = nil) {
        guard busyState == nil else { return }
        preparingState = BusyOverlayState(title: title, detail: detail)
    }

    @MainActor
    func clearPreparingOverlay() {
        preparingState = nil
    }

    @MainActor
    func updateBusyPresentation(
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
    func applyBusyProgressSnapshot(_ snapshot: BatchProgressSnapshot) {
        updateBusyState { state in
            state.apply(snapshot: snapshot)
        }
    }

    @MainActor
    func applyBusyStreamEvent(_ event: OpenAIStreamEvent, sourceID: String, sourceTitle: String) {
        updateBusyState { state in
            state.applyStreamEvent(event, sourceID: sourceID, sourceTitle: sourceTitle)
        }
    }

    func makeSubmissionProcessor(apiKey: String) -> SubmissionProcessor {
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

    func normalizeSessionToIntegerPoints() {
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

    func deleteSession() {
        modelContext.delete(session)
        try? modelContext.save()
        feedbackCenter.show("Session deleted.", tone: .info)
        dismiss()
    }

    @MainActor
    func refreshAllJobStatuses(force: Bool) async {
        await refreshPendingRubricGeneration(force: force)
        await refreshPendingBatchSubmissions(force: force)
    }

    var hasQueuedBatchSubmissions: Bool {
        session.submissions.contains(where: \.isQueuedForRubric)
    }

    var hasRefreshablePendingBatchSubmissions: Bool {
        session.submissions.contains(where: \.isAwaitingRemoteProcessing)
    }

    var pendingRubricPollingID: String {
        session.hasPendingRubricGeneration ? (session.rubricRemoteBatchID ?? "") : ""
    }

    var pendingBatchPollingID: String {
        guard hasRefreshablePendingBatchSubmissions else { return "" }
        let ids = session.submissions
            .filter(\.isAwaitingRemoteProcessing)
            .map(\.id.uuidString)
            .sorted()
        return ids.joined(separator: "|")
    }

    var hasActivePendingBatchRequests: Bool {
        session.submissions.contains(where: \.hasRemoteBatchReservation)
    }

    var filteredSubmissions: [StudentSubmission] {
        let trimmed = resultsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedSubmissions = session.sortedSubmissions
        guard !trimmed.isEmpty else { return sortedSubmissions }
        return sortedSubmissions.filter {
            $0.listDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var completedSubmissions: [StudentSubmission] {
        session.submissions.filter(\.isProcessingCompleted)
    }

    var overallAverageScore: Double? {
        guard !completedSubmissions.isEmpty else { return nil }
        let total = completedSubmissions.reduce(0) { $0 + $1.totalScore }
        return total / Double(completedSubmissions.count)
    }

    var overallAveragePercentage: Double? {
        guard let overallAverageScore, session.totalPossiblePoints > 0 else { return nil }
        return overallAverageScore / session.totalPossiblePoints
    }

    func averageScore(for question: QuestionRubric) -> Double? {
        let scores = completedSubmissions.compactMap { submission -> Double? in
            submission.questionGrades().first(where: { $0.questionID == question.questionID })?.awardedPoints
        }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    func summaryColor(for percentage: Double) -> Color {
        switch percentage {
        case ..<0.5:
            return .red
        case ..<0.8:
            return .orange
        default:
            return .green
        }
    }

    var batchRefreshSummary: BatchRefreshSummary {
        BatchRefreshSummary(
            pending: session.submissions.filter { $0.isAwaitingRemoteProcessing }.count,
            completed: session.submissions.filter { $0.isProcessingCompleted }.count,
            failed: session.submissions.filter { $0.isProcessingFailed }.count
        )
    }

    func batchRefreshFeedbackMessage(
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

struct BatchRefreshSummary {
    let pending: Int
    let completed: Int
    let failed: Int
}
