import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit


enum QRCode {
    static func image(for string: String, scale: CGFloat = 10) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
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
    @EnvironmentObject private var session: AppSession
    @State private var showShareSheet = false
    @State private var copiedMessage: String?

    private var token: InviteToken { InviteToken(event.inviteToken) ?? InviteToken(unchecked: event.inviteToken) }
    /// HTTPS link is for Messages/WhatsApp. In development it intentionally uses
    /// Firebase Hosting rather than the not-yet-configured production domain.
    private var webURL: URL { InviteLink.url(forToken: token) }
    /// QR assumes the other phone has SnapLoop installed and opens the app
    /// directly, avoiding an in-app browser/Universal-Link dependency in MVP.
    private var appURL: URL { URL(string: "\(InviteLink.customScheme)://e/\(token.value)")! }
    private var isOrganizer: Bool { session.user?.id == event.creatorUserId }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "person.3.fill").font(.system(size: 46)).foregroundStyle(Theme.coral)
                Text("Invite people to \(event.name)").font(.title3).bold().multilineTextAlignment(.center)
                Text("Anyone with the invite still has to sign in and explicitly join the event.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                Button { showShareSheet = true } label: {
                    Label("Share Invite", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = JoinCode(canonical: event.joinCode).formatted
                        copiedMessage = "Code copied"
                    } label: { Label("Copy Code", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)

                    Button {
                        UIPasteboard.general.url = webURL
                        copiedMessage = "Invite link copied"
                    } label: { Label("Copy Link", systemImage: "link").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                }

                if isOrganizer {
                    NavigationLink { InvitePeopleView(event: event) } label: {
                        Label("Invite by Phone or Contacts", systemImage: "person.crop.circle.badge.plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }

                VStack(spacing: 12) {
                    Text("Scan in SnapLoop").font(.subheadline).foregroundStyle(.secondary)
                    if let qr = QRCode.image(for: appURL.absoluteString) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 220, height: 220)
                            .accessibilityLabel("QR code to join \(event.name)")
                    }
                    Text(JoinCode(canonical: event.joinCode).formatted)
                        .font(.system(.title2, design: .monospaced)).bold().textSelection(.enabled)
                    Text("Join code").font(.caption).foregroundStyle(.secondary)
                }
                .padding().frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                if let copiedMessage { Text(copiedMessage).font(.caption).foregroundStyle(.secondary) }
            }
            .padding()
        }
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            ActivityView(items: [InviteLink.shareText(eventName: event.name, token: token), webURL])
        }
    }
}
