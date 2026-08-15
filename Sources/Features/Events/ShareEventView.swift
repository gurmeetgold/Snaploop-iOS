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

/// UIKit share sheet bridge for "Share Event → WhatsApp / Messages / Copy Link".
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The invite screen: dominant "Share Link" path plus a QR + short code for
/// in-person joining. The link/code/QR all resolve to the same stable event.
struct ShareEventView: View {
    let event: Event
    @State private var showShareSheet = false

    private var token: InviteToken { InviteToken(event.inviteToken) ?? InviteToken(unchecked: event.inviteToken) }
    private var url: URL { InviteLink.url(forToken: token) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Invite people to \(event.name)")
                    .font(.title3).bold().multilineTextAlignment(.center)

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

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
