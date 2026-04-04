import Foundation
import UserNotifications

@MainActor
final class AppNotificationCoordinator: NSObject {
    static let shared = AppNotificationCoordinator()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    func configure() {
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await requestAuthorization(options: [.alert, .badge, .sound])
    }

    func notifyAnswerKeyReady(sessionTitle: String) async {
        let settings = await notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        await addNotification(
            identifier: "answer-key-ready-\(sessionTitle)",
            title: "Answer Key Ready",
            body: "\(sessionTitle) is ready to review."
        )
    }

    func notifyBatchGradingFinished(sessionTitle: String, completed: Int, failed: Int) async {
        let settings = await notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let body: String
        if failed > 0 {
            body = "\(sessionTitle) finished with \(completed) completed and \(failed) failed submissions."
        } else {
            body = "\(sessionTitle) finished grading \(completed) submissions."
        }

        await addNotification(
            identifier: "grading-finished-\(sessionTitle)",
            title: "Batch Grading Finished",
            body: body
        )
    }

    private func addNotification(identifier: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        try? await addRequest(request)
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func addRequest(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

extension AppNotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
