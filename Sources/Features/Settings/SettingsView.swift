import Photos
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
    @AppStorage("snaploop.onboarding.completed") private var hasCompletedOnboarding = false
    @State private var confirmSignOut = false
    @State private var confirmReplayOnboarding = false
    @State private var facePreviewData: Data?
    @State private var photoAccessStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("You")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    profileCard
                    accountActions
                    photoAccessCard
                    privacyCard
                    onboardingCard
                    signOutCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshFaceReference()
            refreshPhotoAccessStatus()
        }
        .onChange(of: session.hasFaceProfile) { _, _ in refreshFaceReference() }
        .confirmationDialog("Sign out of SnapLoop?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { model.signOut(env: env, session: session) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Replay onboarding?", isPresented: $confirmReplayOnboarding, titleVisibility: .visible) {
            Button("Replay Onboarding") { hasCompletedOnboarding = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll see the SnapLoop introduction again. Your account, Events, photos, and Face Setup will not be changed.")
        }
    }

    private var profileCard: some View {
        PremiumCard {
            HStack(spacing: 14) {
                profileThumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.user?.displayName ?? "Add your name").font(.headline).foregroundStyle(Theme.ink)
                    if let phone = session.user?.phoneNumber {
                        Label(phone, systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
                    }
                    if facePreviewData != nil {
                        Label("Your saved face reference", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(Theme.coral)
                    } else if session.hasFaceProfile {
                        Label("Face Setup ready", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                BrandMark(size: 34)
            }
        }
    }

    @ViewBuilder private var profileThumbnail: some View {
        if let data = facePreviewData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 66, height: 66)
                .clipShape(Circle()).clipped().overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(color: Theme.navy.opacity(0.12), radius: 8, y: 4)
        } else {
            ZStack {
                Circle().fill(Theme.softWash)
                Image(systemName: "person.crop.circle.fill").font(.system(size: 36)).foregroundStyle(Theme.violet.opacity(0.72))
            }
            .frame(width: 66, height: 66).overlay(Circle().strokeBorder(.white, lineWidth: 3))
        }
    }

    private var accountActions: some View {
        PremiumCard {
            VStack(spacing: 0) {
                menuLink(title: session.user?.displayName == nil ? "Add Your Name" : "Edit Your Name", icon: "person.text.rectangle.fill", tint: Theme.sunset) { ProfileNameView() }
                Divider().padding(.leading, 46)
                menuLink(title: session.hasFaceProfile ? "Update Face Setup" : "Set Up Your Face", icon: "faceid", tint: Theme.violet) {
                    FaceSetupView(onSaved: { refreshFaceReference() })
                }
                if session.hasFaceProfile {
                    Divider().padding(.leading, 46)
                    menuLink(title: "Test My Face Setup", icon: "checkmark.circle.fill", tint: Theme.aqua) { FaceMatchingTestView() }
                }
            }
        }
    }

    private var photoAccessCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    iconBadge("photo.on.rectangle.angled", tint: Theme.aqua)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photo Access").font(.headline).foregroundStyle(Theme.ink)
                        Text(photoAccessDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if photoAccessStatus == .limited {
                    Button {
                        presentLimitedLibraryPicker()
                    } label: {
                        Label("Add More Photos", systemImage: "photo.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Theme.socialGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if photoAccessStatus == .denied || photoAccessStatus == .restricted {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open iOS Settings", systemImage: "gear")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.sunset)
                    .background(Theme.peach.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var photoAccessDescription: String {
        switch photoAccessStatus {
        case .authorized: return "All Photos"
        case .limited: return "Selected Photos only — you can add more anytime"
        case .denied, .restricted: return "Photo access is off"
        case .notDetermined: return "Photo access has not been requested yet"
        @unknown default: return "Photo access status unavailable"
        }
    }

    private var privacyCard: some View {
        PremiumCard {
            NavigationLink { PrivacyView() } label: {
                HStack(spacing: 12) {
                    iconBadge("lock.shield.fill", tint: Theme.sky)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privacy & Data").font(.headline).foregroundStyle(Theme.ink)
                        Text("Face data, deletion and account controls").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }.buttonStyle(.plain)
        }
    }

    private var onboardingCard: some View {
        PremiumCard {
            Button { confirmReplayOnboarding = true } label: {
                HStack(spacing: 12) {
                    iconBadge("sparkles.rectangle.stack.fill", tint: Theme.violet)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replay Onboarding").font(.headline).foregroundStyle(Theme.ink)
                        Text("Review how Events, matching and permissions work").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var signOutCard: some View {
        PremiumCard {
            Button(role: .destructive) { confirmSignOut = true } label: {
                HStack(spacing: 12) {
                    iconBadge("rectangle.portrait.and.arrow.right", tint: .red)
                    Text("Sign Out").font(.headline); Spacer()
                }
            }
            if let error = model.errorMessage {
                Divider().padding(.vertical, 8); Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func menuLink<Destination: View>(title: String, icon: String, tint: Color, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 12) {
                iconBadge(icon, tint: tint); Text(title).font(.headline).foregroundStyle(Theme.ink); Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 8)
        }.buttonStyle(.plain)
    }

    private func iconBadge(_ icon: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.13))
            Image(systemName: icon).font(.headline).foregroundStyle(tint)
        }.frame(width: 36, height: 36)
    }

    private func refreshFaceReference() {
        guard let userId = session.user?.id else { facePreviewData = nil; return }
        facePreviewData = LocalFaceReferenceStore.load(userId: userId)
    }

    private func refreshPhotoAccessStatus() {
        photoAccessStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private func presentLimitedLibraryPicker() {
        guard photoAccessStatus == .limited else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshPhotoAccessStatus() }
    }
}
