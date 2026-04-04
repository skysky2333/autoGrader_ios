import SwiftUI
import SwiftData

struct SavedSubmissionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    let submission: StudentSubmission
    let integerPointsOnly: Bool
    let onRegrade: (() -> Void)?
    let onDelete: (() -> Void)?
    @State private var draft: SubmissionDraft
    @State private var isSaving = false
    @State private var showingDeleteConfirmation = false

    init(
        submission: StudentSubmission,
        onRegrade: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.submission = submission
        let integerOnly = submission.session?.integerPointsOnlyEnabled ?? false
        self.integerPointsOnly = integerOnly
        self.onRegrade = onRegrade
        self.onDelete = onDelete
        _draft = State(initialValue: SubmissionDraft.fromStoredSubmission(submission).normalized(integerPointsOnly: integerOnly))
    }

    var body: some View {
        NavigationStack {
            Form {
                if canEditSubmission {
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
                        if draft.needsAttention {
                            HighlightNotice(
                                message: "This submission needs teacher attention before the grade can be trusted.",
                                color: .red
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

                    if draft.needsAttention || !draft.attentionReasonsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section("Attention Reasons") {
                            TextEditor(text: $draft.attentionReasonsText)
                                .frame(minHeight: 120)
                            RenderedPreviewButton(title: "Attention Reasons Preview", text: draft.attentionReasonsText)
                        }
                    }
                } else {
                    Section("Status") {
                        LabeledContent("State", value: submissionStatusTitle)
                        if let batchStageLabel {
                            LabeledContent("Pipeline", value: batchStageLabel)
                        }
                        LabeledContent("Saved", value: submission.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if
                            let detail = submission.processingDetail,
                            !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if
                            !submission.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            submission.overallNotes != submission.processingDetail
                        {
                            Text(submission.overallNotes)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if submission.needsAttentionEnabled || !(submission.attentionReasonsText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section("Needs Attention") {
                            Text(submission.needsAttentionEnabled ? "Yes" : "No")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(submission.needsAttentionEnabled ? .red : .secondary)

                            if let attentionReasonsText = submission.attentionReasonsText, !attentionReasonsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(attentionReasonsText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let validationPayload = submission.latestValidationPayload() {
                        Section("Last Validation Result") {
                            LabeledContent("Validator verdict", value: validationPayload.isGradingCorrect ? "Confirmed" : "Not confirmed")
                            Text(validationPayload.validatorSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if !validationPayload.issues.isEmpty {
                                ForEach(validationPayload.issues, id: \.self) { issue in
                                    Text(issue)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !draft.pageData.isEmpty {
                        Section("Scanned Pages") {
                            ImageStripView(pageData: draft.pageData)
                        }
                    }
                }

                if !debugTraces.isEmpty {
                    Section("Debug") {
                        ForEach(debugTraces) { trace in
                            DisclosureGroup(trace.title) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(trace.entries) { entry in
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Label(debugKindTitle(for: entry.kind), systemImage: debugKindSystemImage(for: entry.kind))
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(debugKindColor(for: entry.kind))
                                                Spacer()
                                                Text(entry.recordedAt.formatted(date: .omitted, time: .shortened))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Text(entry.title)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)

                                            Text(entry.body)
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                                .padding(.top, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if canEditSubmission {
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
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canEditSubmission, let onRegrade {
                            Button("Regrade") {
                                onRegrade()
                            }
                        }

                        if onDelete != nil {
                            Button("Delete", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .keyboardDismissToolbar()
        }
        .feedbackToast()
        .activityOverlay(isPresented: isSaving, text: "Saving submission...")
        .confirmationDialog("Delete this result?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            if let onDelete {
                Button("Delete Result", role: .destructive) {
                    dismiss()
                    onDelete()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(submission.hasRemoteBatchInFlight ? "This removes the local result only. It does not cancel the OpenAI batch job." : "This removes the saved result from the session.")
        }
    }

    private var canEditSubmission: Bool {
        submission.isProcessingCompleted
    }

    private var navigationTitle: String {
        if canEditSubmission {
            return draft.studentName.isEmpty ? "Saved Result" : draft.studentName
        }
        return submission.listDisplayName
    }

    private var submissionStatusTitle: String {
        if submission.isQueuedForRubric {
            return "Queued"
        }
        if submission.isProcessingPending {
            return "Pending"
        }
        if submission.isProcessingFailed {
            return "Failed"
        }
        return "Completed"
    }

    private var batchStageLabel: String? {
        switch submission.batchStage {
        case .queued:
            return "Waiting for rubric approval"
        case .grading:
            return "Initial grading"
        case .validating:
            return "Validation pass \(submission.currentBatchAttemptNumber)"
        case .regrading:
            return "Regrade pass \(submission.currentBatchAttemptNumber)"
        case nil:
            return nil
        }
    }

    private var debugTraces: [SubmissionDebugTrace] {
        var traces = submission.debugInfo()?.sortedTraces ?? []

        if
            let latestSubmissionPayload = submission.latestSubmissionPayload(),
            let data = try? JSONEncoder.prettyPrinted.encode(latestSubmissionPayload),
            let text = String(data: data, encoding: .utf8)
        {
            traces.append(
                SubmissionDebugTrace(
                    id: "stored-submission-payload",
                    title: "Stored Grading Payload",
                    entries: [
                        SubmissionDebugTraceEntry(
                            title: "Latest saved grading payload",
                            body: text,
                            kind: .incoming,
                            recordedAt: submission.createdAt
                        ),
                    ],
                    lastRecordedAt: submission.createdAt
                )
            )
        }

        if
            let latestValidationPayload = submission.latestValidationPayload(),
            let data = try? JSONEncoder.prettyPrinted.encode(latestValidationPayload),
            let text = String(data: data, encoding: .utf8)
        {
            traces.append(
                SubmissionDebugTrace(
                    id: "stored-validation-payload",
                    title: "Stored Validation Payload",
                    entries: [
                        SubmissionDebugTraceEntry(
                            title: "Latest saved validation payload",
                            body: text,
                            kind: .incoming,
                            recordedAt: submission.createdAt
                        ),
                    ],
                    lastRecordedAt: submission.createdAt
                )
            )
        }

        if let info = submission.debugInfo() {
            traces.append(contentsOf: legacyDebugTraces(from: info))
        }

        return traces.sorted { lhs, rhs in
            lhs.lastRecordedAt > rhs.lastRecordedAt
        }
    }

    private func legacyDebugTraces(from info: SubmissionDebugInfo) -> [SubmissionDebugTrace] {
        var traces: [SubmissionDebugTrace] = []

        if let batchStatusJSON = info.batchStatusJSON, !batchStatusJSON.isEmpty {
            traces.append(
                SubmissionDebugTrace(
                    id: "legacy-batch-status",
                    title: "Legacy Batch Status",
                    entries: [
                        SubmissionDebugTraceEntry(
                            title: "Latest batch status JSON",
                            body: batchStatusJSON,
                            kind: .batchStatus,
                            recordedAt: submission.createdAt
                        ),
                    ],
                    lastRecordedAt: submission.createdAt
                )
            )
        }

        if let latestBatchOutputLineJSON = info.latestBatchOutputLineJSON, !latestBatchOutputLineJSON.isEmpty {
            traces.append(
                SubmissionDebugTrace(
                    id: "legacy-batch-output",
                    title: "Legacy Batch Output",
                    entries: [
                        SubmissionDebugTraceEntry(
                            title: "Latest batch output line JSON",
                            body: latestBatchOutputLineJSON,
                            kind: .batchOutput,
                            recordedAt: submission.createdAt
                        ),
                    ],
                    lastRecordedAt: submission.createdAt
                )
            )
        }

        if let latestBatchErrorLineJSON = info.latestBatchErrorLineJSON, !latestBatchErrorLineJSON.isEmpty {
            traces.append(
                SubmissionDebugTrace(
                    id: "legacy-batch-error",
                    title: "Legacy Batch Error",
                    entries: [
                        SubmissionDebugTraceEntry(
                            title: "Latest batch error line JSON",
                            body: latestBatchErrorLineJSON,
                            kind: .batchError,
                            recordedAt: submission.createdAt
                        ),
                    ],
                    lastRecordedAt: submission.createdAt
                )
            )
        }

        if let latestLookupSummary = info.latestLookupSummary, !latestLookupSummary.isEmpty {
            traces.append(
                SubmissionDebugTrace(
                    id: "legacy-lookup-summary",
                    title: "Legacy Lookup Summary",
                    entries: [
                        SubmissionDebugTraceEntry(
                            title: "Latest lookup summary",
                            body: latestLookupSummary,
                            kind: .lookup,
                            recordedAt: submission.createdAt
                        ),
                    ],
                    lastRecordedAt: submission.createdAt
                )
            )
        }

        return traces
    }

    private func debugKindTitle(for kind: SubmissionDebugTraceKind) -> String {
        switch kind {
        case .outgoing:
            return "Sent"
        case .incoming:
            return "Received"
        case .status:
            return "Status"
        case .error:
            return "Error"
        case .batchStatus:
            return "Batch Status"
        case .batchOutput:
            return "Batch Output"
        case .batchError:
            return "Batch Error"
        case .lookup:
            return "Lookup"
        }
    }

    private func debugKindSystemImage(for kind: SubmissionDebugTraceKind) -> String {
        switch kind {
        case .outgoing:
            return "paperplane"
        case .incoming:
            return "tray.and.arrow.down"
        case .status:
            return "info.circle"
        case .error:
            return "exclamationmark.triangle"
        case .batchStatus:
            return "arrow.clockwise"
        case .batchOutput:
            return "text.page"
        case .batchError:
            return "xmark.octagon"
        case .lookup:
            return "magnifyingglass"
        }
    }

    private func debugKindColor(for kind: SubmissionDebugTraceKind) -> Color {
        switch kind {
        case .outgoing:
            return .blue
        case .incoming:
            return .green
        case .status, .batchStatus, .lookup:
            return .secondary
        case .error, .batchError:
            return .red
        case .batchOutput:
            return .orange
        }
    }

    private func saveChanges() {
        let normalized = draft.normalized(integerPointsOnly: integerPointsOnly)
        submission.studentName = normalized.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.nameNeedsReview = normalized.nameNeedsReview
        submission.needsAttention = normalized.needsAttention
        submission.attentionReasonsText = normalized.attentionReasonsText.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.validationNeedsReview = false
        submission.overallNotes = normalized.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.teacherReviewed = true
        submission.processingStateRaw = StudentSubmissionProcessingState.completed.rawValue
        submission.processingDetail = nil
        submission.setLatestValidationPayload(nil)
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
