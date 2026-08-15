import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        List {
            Section("Account") {
                if let phone = session.user?.phoneNumber {
                    LabeledContent("Phone", value: phone)
                }
                NavigationLink { Text("Face setup flow (Onboarding)") } label: {
                    Label(session.hasFaceProfile ? "Update Face Setup" : "Set Up Your Face",
                          systemImage: "faceid")
                }
            }
            Section {
                NavigationLink { PrivacyView() } label: {
                    Label("Privacy & Data", systemImage: "lock.shield")
                }
            }
            Section {
                Text("SnapLoop finds your photos from events on-device. Your photos stay on your phone unless you're in them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
