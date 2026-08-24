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
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareEventView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @State private var showShareSheet = false
    @State private var copiedMessage: String?
    @State private var canManageInvites = false

    private var token: InviteToken { InviteToken(event.inviteToken) ?? InviteToken(unchecked: event.inviteToken) }
    private var url: URL { InviteLink.url(forToken: token) }

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

                    Text("Anyone with the invite can open the Event, sign in, and choose whether to join.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 12)

                    Button { showShareSheet = true } label: {
                        Label("Share Invite", systemImage: "square.and.arrow.up.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Theme.sunset.opacity(0.18), radius: 12, y: 6)

                    HStack(spacing: 12) {
                        secondaryAction("Copy Code", icon: "doc.on.doc.fill") {
                            UIPasteboard.general.string = JoinCode(canonical: event.joinCode).formatted
                            copiedMessage = "Event code copied"
                        }
                        secondaryAction("Copy Link", icon: "link") {
                            UIPasteboard.general.string = url.absoluteString
                            copiedMessage = "Invite link copied"
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

                    if let copiedMessage {
                        Label(copiedMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInvitePermission() }
        .sheet(isPresented: $showShareSheet) {
            // The share text already contains the canonical URL. Passing the URL
            // as a second activity item made apps such as WhatsApp render it twice.
            ActivityView(items: [InviteLink.shareText(eventName: event.name, token: token)])
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

    private func secondaryAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold()).frame(maxWidth: .infinity).frame(height: 50)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.sunset)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Theme.sunset.opacity(0.18)))
    }
}
