import SwiftUI

/// A simple empty/error state view (portable equivalent of `ContentUnavailableView`,
/// which is iOS 17+; this keeps the iOS 16 deployment target).
struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    var systemImage: String = "exclamationmark.triangle"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A compact colored status pill used in headers (sync state, event phase).
struct StatusPill: View {
    let text: String
    var tint: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption).bold()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}
