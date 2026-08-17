import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a QR code for a string (the invite URL) entirely on-device.
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

    private var token: InviteToken { InviteToken(event.inviteToken) ?? InviteToken(unchecked: event.inviteToken) }
    private var url: URL { InviteLink.url(forToken: token) }
    private var isOrganizer: Bool { session.user?.id == event.creatorUserId }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Invite people to \(event.name)")
                    .font(.title3).bold().multilineTextAlignment(.center)

                Button { showShareSheet = true } label: {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if isOrganizer {
                    NavigationLink {
                        InvitePeopleView(event: event)
                    } label: {
                        Label("Add by Phone or Contacts", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                VStack(spacing: 12) {
                    Text("Or scan in person").font(.subheadline).foregroundStyle(.secondary)
                    if let qr = QRCode.image(for: url.absoluteString) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .accessibilityLabel("QR code to join \(event.name)")
                    }
                    Text(JoinCode(canonical: event.joinCode).formatted)
                        .font(.system(.title2, design: .monospaced)).bold()
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
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
