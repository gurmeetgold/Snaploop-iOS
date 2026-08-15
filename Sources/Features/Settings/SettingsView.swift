import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.coralGradient)
                        Text(String((session.user?.displayName ?? "?").prefix(1)).uppercased())
                            .font(.title2).bold().foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.user?.displayName ?? "You").font(.headline)
                        if let phone = session.user?.phoneNumber {
                            Text(phone).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)

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
                Text("SnapLoop finds your photos from trips on-device. Your photos stay on your phone unless you're in them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("You")
    }
}
