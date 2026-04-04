import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct HomeworkGraderApp: App {
    @Environment(\.scenePhase) private var scenePhase
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
                .task {
                    AppNotificationCoordinator.shared.configure()
                    await AppBatchRefreshCoordinator.scheduleAppRefreshIfNeeded(
                        container: sharedModelContainer
                    )
                }
                .onChange(of: scenePhase) { _, newValue in
                    switch newValue {
                    case .background:
                        Task {
                            await AppBatchRefreshCoordinator.scheduleAppRefreshIfNeeded(
                                container: sharedModelContainer
                            )
                        }
                    default:
                        break
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .backgroundTask(.appRefresh(AppBackgroundTaskIDs.refreshPendingJobs)) {
            await AppBatchRefreshCoordinator.refreshPendingWork(
                container: sharedModelContainer,
                triggerNotifications: true
            )
        }
    }
}
