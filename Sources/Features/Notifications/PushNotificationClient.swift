import FirebaseFunctions
import FirebaseMessaging
import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let myPicsRoomInviteReceived = Notification.Name("MyPicsRoomInviteReceived")
}

@MainActor
final class PushNotificationCoordinator: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationCoordinator()

    func start() {
        guard AppEnvironment.useLiveServices else { return }
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else { return }
        Task { try? await PushNotificationClient.registerFCMToken(fcmToken) }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        PushNotificationClient.capturePushPayload(notification.request.content.userInfo)
        return [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        PushNotificationClient.capturePushPayload(response.notification.request.content.userInfo)
    }
}

enum PushNotificationClient {
    @MainActor
    static func requestAuthorizationAndRegister() async {
        guard AppEnvironment.useLiveServices else { return }
        PushNotificationCoordinator.shared.start()

        do {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            }
            UIApplication.shared.registerForRemoteNotifications()

            let token = try await Messaging.messaging().token()
            try await registerFCMToken(token)
        } catch {
            Log.events.error("Push registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    static func registerFCMToken(_ token: String) async throws {
        guard AppEnvironment.useLiveServices, !token.isEmpty else { return }
        let callable = Functions.functions().httpsCallable("registerPushToken")
        _ = try await callable.call([
            "token": token,
            "platform": "ios",
            "appBundleId": Bundle.main.bundleIdentifier ?? "",
        ])
    }

    static func capturePushPayload(_ userInfo: [AnyHashable: Any]) {
        let inviteToken = userInfo["inviteToken"] as? String
        let eventId = userInfo["eventId"] as? String

        if let inviteToken, let token = InviteToken(inviteToken) {
            PendingInviteStore.save(.joinEventByToken(token))
            NotificationCenter.default.post(name: .myPicsRoomInviteReceived, object: nil)
            return
        }

        if let eventId, !eventId.isEmpty {
            NotificationCenter.default.post(name: .myPicsRoomInviteReceived, object: eventId)
        }
    }
}
