import SwiftUI
import SwiftData

@main
struct HomeworkGraderApp: App {
    @StateObject private var feedbackCenter = FeedbackCenter()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            GradingSession.self,
            QuestionRubric.self,
            StudentSubmission.self,
        ])

        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(feedbackCenter)
        }
        .modelContainer(sharedModelContainer)
    }
}
