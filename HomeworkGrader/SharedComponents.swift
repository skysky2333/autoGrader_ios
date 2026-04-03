import SwiftUI
import UIKit

enum FeedbackToastTone: Equatable {
    case success
    case info
    case error

    var systemImage: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success:
            return .green
        case .info:
            return .blue
        case .error:
            return .red
        }
    }

    var hapticType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .success:
            return .success
        case .info:
            return .warning
        case .error:
            return .error
        }
    }
}

struct FeedbackToastState: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let tone: FeedbackToastTone
}

@MainActor
final class FeedbackCenter: ObservableObject {
    @Published private(set) var toast: FeedbackToastState?
    @Published private var presenterStack: [UUID] = []
    private var dismissTask: Task<Void, Never>?

    func show(
        _ message: String,
        tone: FeedbackToastTone = .success,
        durationNanoseconds: UInt64 = 2_000_000_000
    ) {
        dismissTask?.cancel()

        let nextToast = FeedbackToastState(message: message, tone: tone)
        UINotificationFeedbackGenerator().notificationOccurred(tone.hapticType)

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            toast = nextToast
        }

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            guard !Task.isCancelled else { return }
            guard self?.toast?.id == nextToast.id else { return }

            withAnimation(.easeOut(duration: 0.2)) {
                self?.toast = nil
            }
        }
    }

    func registerPresenter(_ id: UUID) {
        presenterStack.removeAll { $0 == id }
        presenterStack.append(id)
    }

    func unregisterPresenter(_ id: UUID) {
        presenterStack.removeAll { $0 == id }
    }

    func isActivePresenter(_ id: UUID) -> Bool {
        presenterStack.last == id
    }
}

struct SubmissionRow: View {
    let submission: StudentSubmission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(submission.listDisplayName)
                    .font(.headline)
                Spacer()
                if submission.isProcessingCompleted {
                    Text("\(ScoreFormatting.scoreString(submission.totalScore)) / \(ScoreFormatting.scoreString(submission.maxScore))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(submission.isProcessingPending ? "Pending" : "Failed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(submission.isProcessingPending ? .orange : .red)
                }
            }

            Text(submission.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            if
                let detail = submission.processingDetail,
                !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if submission.isProcessingPending {
                StatusChip(label: "Pending", color: .orange)
            }

            if submission.isProcessingFailed {
                StatusChip(label: "Failed", color: .red)
            }

            if submission.validationNeedsReviewEnabled {
                StatusChip(label: "Validation Inconclusive", color: .orange)
            }

            if submission.nameNeedsReviewEnabled || (submission.isProcessingCompleted && submission.hasQuestionNeedingReview) {
                StatusChip(label: "Review Needed", color: .orange)
            }
        }
        .padding(.vertical, 4)
    }
}

func gradeNeedsHighlight(_ grade: QuestionGradeRecord) -> Bool {
    grade.needsReview || grade.awardedPoints + 0.001 < grade.maxPoints
}

struct GradeSectionHeader: View {
    let title: String
    let isHighlighted: Bool

    var body: some View {
        HStack {
            Text(title)
            if isHighlighted {
                Spacer()
                Text("Review")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct HighlightNotice: View {
    let message: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(color)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ModelTextField: View {
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

struct APIAdvancedSettingsEditor: View {
    @Binding var validationEnabled: Bool
    @Binding var answerReasoningEffort: String?
    @Binding var gradingReasoningEffort: String?
    @Binding var validationReasoningEffort: String?
    @Binding var answerVerbosity: String?
    @Binding var gradingVerbosity: String?
    @Binding var validationVerbosity: String?
    @Binding var answerServiceTier: String?
    @Binding var gradingServiceTier: String?
    @Binding var validationServiceTier: String?

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
                title: "Validation reasoning effort",
                selection: $validationReasoningEffort,
                options: APIRequestTuningCatalog.reasoningEffortOptions
            )
            .disabled(!validationEnabled)
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
                title: "Validation verbosity",
                selection: $validationVerbosity,
                options: APIRequestTuningCatalog.verbosityOptions
            )
            .disabled(!validationEnabled)
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
            AdvancedSettingPicker(
                title: "Validation service tier",
                selection: $validationServiceTier,
                options: APIRequestTuningCatalog.serviceTierOptions
            )
            .disabled(!validationEnabled)
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

struct SubmissionDraftSummaryRow: View {
    let draft: SubmissionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unnamed Student" : draft.studentName)
                    .font(.headline)
                Spacer()
                Text("\(ScoreFormatting.scoreString(draft.totalScore)) / \(ScoreFormatting.scoreString(draft.maxScore))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if draft.validationNeedsReview {
                StatusChip(label: "Validation Inconclusive", color: .orange)
            }

            if draft.nameNeedsReview || draft.grades.contains(where: \.needsReview) {
                StatusChip(label: "Review Needed", color: .orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusChip: View {
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

struct BusyOverlay: View {
    let state: BusyOverlayState

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
            VStack {
                VStack(alignment: .leading, spacing: 16) {
                    if let progressValue = state.progressValue {
                        ProgressView(value: progressValue)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.title)
                            .font(.headline)
                        if let progressLabel = state.progressLabel {
                            Text(progressLabel)
                                .font(.subheadline.weight(.semibold))
                        }
                        if let detail = state.detail {
                            DisclosureGroup("Details") {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                            .font(.subheadline)
                        }
                    }

                    if !state.transcriptEntries.isEmpty {
                        DisclosureGroup("Request Log") {
                            Divider()
                                .padding(.vertical, 4)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(state.transcriptEntries) { entry in
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(entry.title)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(transcriptColor(for: entry.kind))
                                                Spacer()
                                                if entry.isStreaming {
                                                    ProgressView()
                                                        .controlSize(.small)
                                                }
                                            }

                                            Text(entry.body)
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(12)
                                        .background(transcriptBackground(for: entry.kind), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                            .frame(maxHeight: 320)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(22)
                .frame(maxWidth: 680)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 16)
            }
        }
    }

    private func transcriptColor(for kind: BusyTranscriptKind) -> Color {
        switch kind {
        case .outgoing:
            return .blue
        case .incoming:
            return .green
        case .status:
            return .secondary
        case .error:
            return .red
        }
    }

    private func transcriptBackground(for kind: BusyTranscriptKind) -> Color {
        switch kind {
        case .outgoing:
            return Color.blue.opacity(0.10)
        case .incoming:
            return Color.green.opacity(0.10)
        case .status:
            return Color.secondary.opacity(0.10)
        case .error:
            return Color.red.opacity(0.10)
        }
    }
}

private struct FeedbackToastView: View {
    let toast: FeedbackToastState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.tone.systemImage)
                .foregroundStyle(toast.tone.color)
            Text(toast.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(toast.tone.color.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .allowsHitTesting(false)
    }
}

private struct FeedbackToastModifier: ViewModifier {
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    @State private var presenterID = UUID()

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if
                let toast = feedbackCenter.toast,
                feedbackCenter.isActivePresenter(presenterID)
            {
                FeedbackToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            feedbackCenter.registerPresenter(presenterID)
        }
        .onDisappear {
            feedbackCenter.unregisterPresenter(presenterID)
        }
    }
}

private struct ActivityOverlayView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.10), radius: 10, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .allowsHitTesting(false)
    }
}

private struct ActivityOverlayModifier: ViewModifier {
    let isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isPresented {
                ActivityOverlayView(text: text)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    let message: String
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

enum OrganizationCostState: Equatable {
    case idle
    case loading
    case loaded(OrganizationCostSummary)
    case unavailable(String)
}

private struct KeyboardDismissToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .keyboard) {
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

extension View {
    func keyboardDismissToolbar() -> some View {
        modifier(KeyboardDismissToolbarModifier())
    }

    func feedbackToast() -> some View {
        modifier(FeedbackToastModifier())
    }

    func activityOverlay(isPresented: Bool, text: String) -> some View {
        modifier(ActivityOverlayModifier(isPresented: isPresented, text: text))
    }
}
