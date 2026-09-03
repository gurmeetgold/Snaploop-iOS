import FirebaseFunctions
import FirebaseMessaging
import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let myPicsRoomInviteReceived = Notification.Name("MyPicsRoomInviteReceived")
    static let snapLoopInviteDeclined = Notification.Name("SnapLoopInviteDeclined")
}

@MainActor
final class PushNotificationCoordinator: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationCoordinator()
    static let eventInviteCategoryID = "SNAPLOOP_EVENT_INVITE"
    static let openInviteActionID = "OPEN_INVITE"

    func start() {
        guard AppEnvironment.useLiveServices else { return }
        Messaging.messaging().delegate = self
        let openInvite = UNNotificationAction(
            identifier: Self.openInviteActionID,
            title: "Open Invite",
            options: [.foreground]
        )
        let eventInviteCategory = UNNotificationCategory(
            identifier: Self.eventInviteCategoryID,
            actions: [openInvite],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([eventInviteCategory])
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

    /// Remove already-delivered or still-pending iOS invite notifications for the
    /// Event after the server accepts a decline. Server notification records are
    /// deleted separately by `declineEventInvite`; this closes the device-local
    /// presentation surface as well without affecting invitations for other Events.
    @MainActor
    static func removeInviteNotifications(eventId: String) async {
        guard !eventId.isEmpty else { return }
        let center = UNUserNotificationCenter.current()

        let delivered = await center.deliveredNotifications()
        let deliveredIds = delivered.compactMap { notification -> String? in
            let payloadEventId = notification.request.content.userInfo["eventId"] as? String
            return payloadEventId == eventId ? notification.request.identifier : nil
        }
        if !deliveredIds.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
        }

        let pending = await center.pendingNotificationRequests()
        let pendingIds = pending.compactMap { request -> String? in
            let payloadEventId = request.content.userInfo["eventId"] as? String
            return payloadEventId == eventId ? request.identifier : nil
        }
        if !pendingIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIds)
        }
    }

    static func capturePushPayload(_ userInfo: [AnyHashable: Any]) {
        let inviteToken = userInfo["inviteToken"] as? String
        let eventId = userInfo["eventId"] as? String

        if let inviteToken, let token = InviteToken(inviteToken) {
            let route = DeepLinkRoute.joinEventByToken(token)
            PendingInviteStore.save(route)
            NotificationCenter.default.post(name: .myPicsRoomInviteReceived, object: route)
            return
        }

        if let eventId, !eventId.isEmpty {
            NotificationCenter.default.post(name: .myPicsRoomInviteReceived, object: eventId)
        }
    }
}
