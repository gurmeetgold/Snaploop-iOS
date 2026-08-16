import UIKit
import FirebaseAuth

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        // Only initialize/use Firebase when SnapLoop is running in LIVE mode.
        //
        // FirebaseBootstrap.configureIfNeeded() is safe to call here because
        // it already guarantees FirebaseApp.configure() happens only once.
        if AppEnvironment.useLiveServices {
            FirebaseBootstrap.configureIfNeeded()

            // Firebase Phone Auth uses silent APNs verification when available.
            // No user notification-permission prompt is required for silent
            // Phone Auth verification.
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
        // On Simulator, APNs registration may not behave like a physical
        // device. Firebase Phone Auth can fall back to reCAPTCHA.
        print("APNs registration failed: \(error.localizedDescription)")
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

        // Give Firebase Auth the first opportunity to consume the silent
        // notification used for phone-number authentication.
        if Auth.auth().canHandleNotification(userInfo) {
            completionHandler(.noData)
            return
        }

        // SnapLoop currently has no other remote-notification processing here.
        completionHandler(.noData)
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard AppEnvironment.useLiveServices else {
            return false
        }

        // Handles Firebase Auth callback URLs, including reCAPTCHA fallback.
        if Auth.auth().canHandle(url) {
            return true
        }

        return false
    }
}//
//  AppDelegate.swift
//  SnapLoop
//
//  Created by GC Macbook Air 15 on 2026-08-15.
//

