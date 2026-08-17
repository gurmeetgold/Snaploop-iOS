import FirebaseAuth
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if AppEnvironment.useLiveServices {
            FirebaseBootstrap.configureIfNeeded()
            // Firebase Phone Auth prefers silent APNs app verification. The
            // reCAPTCHA screen remains Firebase's fallback when silent
            // verification is unavailable; SnapLoop does not bypass it.
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard AppEnvironment.useLiveServices else { return }
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Log.auth.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard AppEnvironment.useLiveServices else {
            completionHandler(.noData)
            return
        }
        if Auth.auth().canHandleNotification(userInfo) {
            completionHandler(.noData)
            return
        }
        completionHandler(.noData)
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        // Firebase must see its callback URLs first so phone-auth reCAPTCHA
        // fallback remains functional.
        if AppEnvironment.useLiveServices, Auth.auth().canHandle(url) {
            return true
        }

        // SnapLoop event QR / development landing pages use the registered
        // custom scheme. SwiftUI's .onOpenURL performs the actual route parse;
        // returning true here tells UIKit that this URL belongs to SnapLoop.
        if url.scheme?.lowercased() == InviteLink.customScheme {
            return true
        }

        return false
    }
}
