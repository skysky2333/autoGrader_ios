import Foundation

enum ModelCatalog {
    static let suggestions = [
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5-mini",
        "gpt-4.1",
        "gpt-4.1-mini",
    ]

    static let defaultAnswerModel = "gpt-5.4"
    static let defaultGradingModel = "gpt-5.4"
    static let defaultValidationModel = "gpt-5.4"
}

struct APIRequestTuningOption: Identifiable, Hashable, Sendable {
    let label: String
    let value: String?

    var id: String { "\(label)|\(value ?? "__nil__")" }
}

enum APIRequestTuningCatalog {
    static let reasoningEffortOptions = [
        APIRequestTuningOption(label: "API Default", value: nil),
        APIRequestTuningOption(label: "None", value: "none"),
        APIRequestTuningOption(label: "Minimal", value: "minimal"),
        APIRequestTuningOption(label: "Low", value: "low"),
        APIRequestTuningOption(label: "Medium", value: "medium"),
        APIRequestTuningOption(label: "High", value: "high"),
        APIRequestTuningOption(label: "XHigh", value: "xhigh"),
    ]

    static let verbosityOptions = [
        APIRequestTuningOption(label: "API Default", value: nil),
        APIRequestTuningOption(label: "Low", value: "low"),
        APIRequestTuningOption(label: "Medium", value: "medium"),
        APIRequestTuningOption(label: "High", value: "high"),
    ]

    static let serviceTierOptions = [
        APIRequestTuningOption(label: "Auto (API Default)", value: nil),
        APIRequestTuningOption(label: "Default", value: "default"),
        APIRequestTuningOption(label: "Flex", value: "flex"),
        APIRequestTuningOption(label: "Priority", value: "priority"),
    ]

    static func label(for value: String?, in options: [APIRequestTuningOption]) -> String {
        options.first(where: { $0.value == value })?.label ?? "API Default"
    }
}

enum StudentSubmissionProcessingState: String, Codable, Sendable {
    case completed
    case pending
    case failed
}

enum StudentSubmissionBatchStage: String, Codable, Sendable {
    case queued
    case grading
    case validating
    case regrading
}

enum RubricGenerationProcessingState: String, Codable, Sendable {
    case pending
    case failed
}
