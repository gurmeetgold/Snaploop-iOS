import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

enum QRCode {
    static func image(for string: String, scale: CGFloat = 10) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
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
    @EnvironmentObject private var session: AppSession
    @State private var showShareSheet = false
    @State private var copiedMessage: String?

    private var token: InviteToken { InviteToken(event.inviteToken) ?? InviteToken(unchecked: event.inviteToken) }
    private var url: URL { InviteLink.url(forToken: token) }
    private var isOrganizer: Bool { session.user?.id == event.creatorUserId }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.coral)

                Text("Invite people to \(event.name)")
                    .font(.title3).bold().multilineTextAlignment(.center)

                Text("Anyone with this invite can open the event, sign in, and choose whether to join.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button { showShareSheet = true } label: {
                    Label("Share Invite", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = JoinCode(canonical: event.joinCode).formatted
                        copiedMessage = "Code copied"
                    } label: {
                        Label("Copy Code", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        copiedMessage = "Link copied"
                    } label: {
                        Label("Copy Link", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if isOrganizer {
                    NavigationLink {
                        InvitePeopleView(event: event)
                    } label: {
                        Label("Invite by Phone or Contacts", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                VStack(spacing: 12) {
                    Text("Scan to join").font(.subheadline).foregroundStyle(.secondary)
                    if let qr = QRCode.image(for: url.absoluteString) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .accessibilityLabel("QR code to join \(event.name)")
                    }
                    Text(JoinCode(canonical: event.joinCode).formatted)
                        .font(.system(.title2, design: .monospaced)).bold()
                        .textSelection(.enabled)
                    Text("Event code")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                if let copiedMessage {
                    Text(copiedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                Text("Test invites use \(InviteLink.host) until the production domain and App Store listing are live.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                #endif
            }
            .padding()
        }
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            ActivityView(items: [InviteLink.shareText(eventName: event.name, token: token), url])
        }
    }
}
