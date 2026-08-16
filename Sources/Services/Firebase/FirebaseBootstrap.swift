import Firebase

/// Configures the Firebase SDK exactly once, on first use.
///
/// Called only from `AppEnvironment.live()` — the `.dev()` environment never
/// touches this, so a fresh checkout keeps building and running with zero
/// credentials until you're ready to test against a real Firebase project.
enum FirebaseBootstrap {
    private static var didConfigure = false

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        FirebaseApp.configure()
        didConfigure = true
    }
}
