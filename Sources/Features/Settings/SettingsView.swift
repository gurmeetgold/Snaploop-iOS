import SwiftUI
import UIKit

@MainActor
final class SettingsModel: ObservableObject {
    @Published var errorMessage: String?

    func signOut(env: AppEnvironment, session: AppSession) {
        do {
            try env.auth.signOut()
            session.clearAuthenticatedSession()
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.unknown("\(error)").userMessage
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = SettingsModel()
    @State private var confirmSignOut = false
    @State private var facePreviewData: Data?

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("You")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal)

                    profileCard
                    accountActions
                    privacyCard
                    signOutCard

                    Text("MyPicsTube finds confident photo matches from your events on-device. Only matched optimized previews are shared with event members in the current MVP.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 4)
                }
                .padding(.vertical, 16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshLocalFacePreview() }
        .confirmationDialog("Sign out of MyPicsTube?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                model.signOut(env: env, session: session)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var profileCard: some View {
        PremiumCard {
            HStack(spacing: 14) {
                profileThumbnail

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.user?.displayName ?? "Add your name")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    if let phone = session.user?.phoneNumber {
                        Label(phone, systemImage: "iphone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if facePreviewData != nil {
                        Label("Your saved face reference", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.coral)
                    }
                }
                Spacer()
                BrandMark(size: 38)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var profileThumbnail: some View {
        if let data = facePreviewData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 66, height: 66)
                .clipShape(Circle())
                .clipped()
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(color: Theme.navy.opacity(0.12), radius: 8, y: 4)
        } else {
            ZStack {
                Circle().fill(Theme.brandGradient)
                Text(profileInitial)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .frame(width: 66, height: 66)
        }
    }

    private var accountActions: some View {
        PremiumCard {
            VStack(spacing: 0) {
                menuLink(title: session.user?.displayName == nil ? "Add Your Name" : "Edit Your Name", icon: "person.text.rectangle.fill", tint: Theme.sunset) {
                    ProfileNameView()
                }
                Divider().padding(.leading, 46)
                menuLink(title: session.hasFaceProfile ? "Update Face Setup" : "Set Up Your Face", icon: "faceid", tint: Theme.violet) {
                    FaceSetupView()
                }
                if session.hasFaceProfile {
                    Divider().padding(.leading, 46)
                    menuLink(title: "Test My Face Setup", icon: "checkmark.viewfinder", tint: Theme.aqua) {
                        FaceMatchingTestView()
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private var privacyCard: some View {
        PremiumCard {
            NavigationLink { PrivacyView() } label: {
                HStack(spacing: 12) {
                    iconBadge("lock.shield.fill", tint: Theme.sky)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privacy & Data").font(.headline).foregroundStyle(Theme.ink)
                        Text("Face data, deletion and account controls")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    private var signOutCard: some View {
        PremiumCard {
            Button(role: .destructive) { confirmSignOut = true } label: {
                HStack(spacing: 12) {
                    iconBadge("rectangle.portrait.and.arrow.right", tint: .red)
                    Text("Sign Out").font(.headline)
                    Spacer()
                }
            }

            if let error = model.errorMessage {
                Divider().padding(.vertical, 8)
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
    }

    private func menuLink<Destination: View>(title: String, icon: String, tint: Color, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 12) {
                iconBadge(icon, tint: tint)
                Text(title).font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func iconBadge(_ icon: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.opacity(0.13))
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
        }
        .frame(width: 36, height: 36)
    }

    private func refreshLocalFacePreview() {
        facePreviewData = session.user.flatMap { LocalFaceReferenceStore.load(userId: $0.id) }
    }

    private var profileInitial: String {
        if let name = session.user?.displayName, let first = name.first { return String(first).uppercased() }
        if let phone = session.user?.phoneNumber { return String(phone.suffix(2)) }
        return "?"
    }
}
