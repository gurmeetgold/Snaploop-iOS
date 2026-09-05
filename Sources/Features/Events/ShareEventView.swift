import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

enum QRCode {
    static func image(for string: String, scale: CGFloat = 10) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = context.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let onCompletion: ((Bool) -> Void)?

    init(
        items: [Any],
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        self.items = items
        self.onCompletion = onCompletion
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onCompletion?(completed)
        }
        return controller
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}

struct ShareEventView: View {
    private enum CopyAction: Equatable {
        case code
        case link
    }

    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @State private var showShareSheet = false
    @State private var copiedMessage: String?
    @State private var copiedAction: CopyAction?
    @State private var canManageInvites = false

    private var token: InviteToken { InviteToken(event.inviteToken) ?? InviteToken(unchecked: event.inviteToken) }
    private var url: URL { InviteLink.url(forToken: token) }
    private var inviterName: String? {
        let value = session.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandMark(size: 64)
                    Text("Invite people to \(event.name)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)

                    if let inviterName {
                        Text("Your invite will show that it was sent by \(inviterName). Anyone with the invite can open the Event, sign in, and choose whether to join.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 12)
                    } else {
                        Text("Anyone with the invite can open the Event, sign in, and choose whether to join.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 12)
                    }

                    Button { showShareSheet = true } label: {
                        Label("Share Invite", systemImage: "square.and.arrow.up.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Theme.sunset.opacity(0.18), radius: 12, y: 6)

                    HStack(spacing: 12) {
                        secondaryAction(
                            copiedAction == .code ? "Copied" : "Copy Code",
                            icon: copiedAction == .code ? "checkmark.circle.fill" : "doc.on.doc.fill",
                            confirmed: copiedAction == .code
                        ) {
                            UIPasteboard.general.string = JoinCode(canonical: event.joinCode).formatted
                            showCopyFeedback(.code, message: "Event code copied")
                        }
                        secondaryAction(
                            copiedAction == .link ? "Copied" : "Copy Link",
                            icon: copiedAction == .link ? "checkmark.circle.fill" : "link",
                            confirmed: copiedAction == .link
                        ) {
                            UIPasteboard.general.string = url.absoluteString
                            showCopyFeedback(.link, message: "Invite link copied")
                        }
                    }

                    if canManageInvites {
                        NavigationLink { InvitePeopleView(event: event) } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).fill(Theme.aqua.opacity(0.14))
                                    Image(systemName: "person.crop.circle.badge.plus").font(.title3).foregroundStyle(Theme.aqua)
                                }
                                .frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Invite by Phone or Contacts").font(.headline).foregroundStyle(Theme.ink)
                                    Text("Existing users get an in-app invite; others can receive the link.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .myPicsTubeCard()
                        }
                        .buttonStyle(.plain)
                    }

                    PremiumCard {
                        VStack(spacing: 14) {
                            Label("Scan to join", systemImage: "qrcode.viewfinder")
                                .font(.headline).foregroundStyle(Theme.ink)
                            if let qr = QRCode.image(for: url.absoluteString) {
                                Image(uiImage: qr)
                                    .interpolation(.none).resizable().scaledToFit()
                                    .frame(width: 220, height: 220).padding(10)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 18))
                                    .accessibilityLabel("QR code to join \(event.name)")
                            }
                            Text(JoinCode(canonical: event.joinCode).formatted)
                                .font(.system(.title2, design: .monospaced).bold())
                                .foregroundStyle(Theme.ink).textSelection(.enabled)
                            Text("Event code").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
        }
        .overlay(alignment: .top) {
            if let copiedMessage {
                Label(copiedMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInvitePermission() }
        .sheet(isPresented: $showShareSheet) {
            // Keep the canonical URL in one activity item so messaging apps do
            // not render the same invitation link twice.
            ActivityView(items: [InviteLink.shareText(
                eventName: event.name,
                inviterName: inviterName,
                token: token
            )])
        }
    }

    @MainActor
    private func showCopyFeedback(_ action: CopyAction, message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.16)) {
            copiedAction = action
            copiedMessage = message
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard copiedAction == action else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                copiedAction = nil
                copiedMessage = nil
            }
        }
    }

    @MainActor
    private func loadInvitePermission() async {
        guard let userId = session.user?.id else { return }
        if event.creatorUserId == userId {
            canManageInvites = true
            return
        }
        let roster = (try? await env.events.members(eventId: event.id)) ?? []
        canManageInvites = roster.first(where: { $0.userId == userId })?.role.canManageMembers == true
    }

    private func secondaryAction(
        _ title: String,
        icon: String,
        confirmed: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold()).frame(maxWidth: .infinity).frame(height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(confirmed ? Color.green : Theme.sunset)
        .background(
            confirmed ? Color.green.opacity(0.10) : Color.white.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .strokeBorder((confirmed ? Color.green : Theme.sunset).opacity(0.22))
        )
    }
}
