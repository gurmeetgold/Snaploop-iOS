import Firebase
import FirebaseAuth
import Foundation

/// Configures the Firebase SDK exactly once, on first use.
enum FirebaseBootstrap {
    private static var didConfigure = false
    private static let installMarkerKey = "snaploop.install.marker.v1"

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        FirebaseApp.configure()
        didConfigure = true
        resetPersistedAuthAfterFreshInstallIfNeeded()
    }

    /// Firebase Auth persists credentials in Keychain, which can survive deleting
    /// the app. UserDefaults does not. Shipping an install marker from the first
    /// public release lets a reinstall start signed out without signing users out
    /// during ordinary app updates or launches.
    private static func resetPersistedAuthAfterFreshInstallIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: installMarkerKey) else { return }
        defaults.set(true, forKey: installMarkerKey)

        guard Auth.auth().currentUser != nil else { return }
        do {
            try Auth.auth().signOut()
        } catch {
            Log.auth.error("Fresh-install Firebase sign-out failed: \(String(describing: error), privacy: .public)")
        }
    }
}
