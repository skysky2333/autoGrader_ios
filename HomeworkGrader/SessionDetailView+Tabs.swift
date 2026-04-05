import SwiftUI

extension SessionDetailView {
    @ViewBuilder
    var overviewSections: some View {
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
            Section("Student Scans") {
                Button {
                    startBatchStudentScan()
                } label: {
                    Label("Batch Add Student Scans", systemImage: "square.stack.3d.down.right")
                }
                .disabled(!hasAPIKey || session.isFinished)

                Menu {
                    Button {
                        startStudentScan()
                    } label: {
                        Label("Single-Student Scan", systemImage: "camera.viewfinder")
                    }
                } label: {
                    Label("More Options", systemImage: "ellipsis.circle")
                }
                .disabled(!hasAPIKey || session.isFinished)

                if session.isFinished {
                    Text("This session is marked as ended. Turn off Session ended to grade more submissions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Batch add is the default workflow. Enter pages per submission, capture the stack, and review the finished results later from the Results tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Use More Options for a single-student fallback when a paper has irregular page counts or you need an immediate one-off review.")
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
    var rubricSections: some View {
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
    var resultsSections: some View {
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
}
