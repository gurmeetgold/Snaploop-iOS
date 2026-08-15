import SwiftUI

/// Home skeleton: your events, and the two entry points to the core loop —
/// create an event or join one. Real event list/creation UI arrives with the
/// Events feature; this establishes the shell and the human-first copy tone.
struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    emptyState
                }
                .padding()
            }
            .navigationTitle("SnapLoop")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Get every photo of you")
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text("from everyone's camera — automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("You're not in any events yet.")
                .font(.headline)
            Text("Create an event for your trip or party, or join one with a code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button {
                    // Wired to event creation in the Events feature.
                } label: {
                    Label("Create an event", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    // Wired to join-by-code / QR in the Events feature.
                } label: {
                    Label("Join with a code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    HomeView().environmentObject(AppEnvironment.dev())
}
