import SwiftUI

@MainActor
final class PhoneAuthModel: ObservableObject {
    enum Stage { case enterPhone; case enterCode(verificationId: String) }

    @Published var stage: Stage = .enterPhone
    @Published var selectedCountry: PhoneCountry = .localeDefault
    @Published var phoneNumber = ""
    @Published var normalizedPhoneNumber: String?
    @Published var code = ""
    @Published var isBusy = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?
    private var authTask: Task<Void, Never>?

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    /// Starts the visual busy state synchronously from the button tap, then lets
    /// SwiftUI render that feedback before Firebase begins app verification.
    /// This prevents a slow Firebase/APNs/reCAPTCHA setup from making the button
    /// appear unresponsive and also makes repeated taps unnecessary.
    func beginSendCode() {
        guard !isBusy, let env else { return }
        guard let e164 = PhoneNumberNormalizer.e164(localInput: phoneNumber, country: selectedCountry) else {
            errorMessage = AppError.invalidPhoneNumber.userMessage
            return
        }

        normalizedPhoneNumber = e164
        isBusy = true
        errorMessage = nil
        env.analytics.log(.phoneVerificationStarted())
        authTask?.cancel()

        authTask = Task { [weak self] in
            // Give the pressed state/spinner one render turn before Firebase can
            // perform any synchronous app-verification setup on this actor.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            do {
                let verificationId = try await env.auth.startPhoneVerification(phoneNumber: e164)
                guard !Task.isCancelled else { return }
                self.stage = .enterCode(verificationId: verificationId)
                self.isBusy = false
            } catch let error as AppError {
                guard !Task.isCancelled else { return }
                env.analytics.log(.phoneVerificationFailed())
                self.errorMessage = error.userMessage
                self.isBusy = false
            } catch {
                guard !Task.isCancelled else { return }
                env.analytics.log(.phoneVerificationFailed())
                self.errorMessage = AppError.unknown("\(error)").userMessage
                self.isBusy = false
            }
        }
    }

    func beginVerifyCode() {
        guard !isBusy, let env, let session, case .enterCode(let verificationId) = stage else { return }
        guard code.count >= 6 else { return }

        isBusy = true
        errorMessage = nil
        authTask?.cancel()

        let submittedCode = code
        let canonicalPhone = normalizedPhoneNumber
            ?? PhoneNumberNormalizer.e164(localInput: phoneNumber, country: selectedCountry)
            ?? phoneNumber

        authTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            do {
                let uid = try await env.auth.confirmVerification(
                    verificationId: verificationId,
                    code: submittedCode
                )
                guard !Task.isCancelled else { return }

                var createdNewUser = false
                let user: User
                do {
                    user = try await env.users.fetch(userId: uid)
                } catch let error as AppError {
                    if case .backend(let backendCode, _) = error, backendCode == "user_not_found" {
                        let created = User(
                            id: uid,
                            phoneNumber: canonicalPhone,
                            displayName: nil,
                            hasFaceProfile: false,
                            createdAt: env.clock.now()
                        )
                        try await env.users.save(created)
                        user = created
                        createdNewUser = true
                    } else {
                        throw error
                    }
                }

                let storedProfile = try await env.faceProfiles.load(userId: uid)
                let currentProfile: FaceProfile?
                if let storedProfile,
                   storedProfile.userId == uid,
                   storedProfile.version == FaceModelPolicy.currentVersion {
                    currentProfile = storedProfile
                } else {
                    currentProfile = nil
                }

                var resolvedUser = user
                if resolvedUser.hasFaceProfile != (currentProfile != nil) {
                    resolvedUser.hasFaceProfile = currentProfile != nil
                    try? await env.users.save(resolvedUser)
                }

                guard !Task.isCancelled else { return }
                session.beginAuthenticatedSession(
                    user: resolvedUser,
                    faceProfile: currentProfile,
                    faceProfileResolved: true
                )
                env.analytics.log(.phoneVerificationSucceeded())
                if createdNewUser {
                    env.analytics.log(.signupCompleted())
                }
                env.analytics.log(.loginSucceeded())
                self.isBusy = false
            } catch let error as AppError {
                guard !Task.isCancelled else { return }
                env.analytics.log(.phoneVerificationFailed())
                self.errorMessage = error.userMessage
                self.isBusy = false
            } catch {
                guard !Task.isCancelled else { return }
                env.analytics.log(.phoneVerificationFailed())
                self.errorMessage = AppError.unknown("\(error)").userMessage
                self.isBusy = false
            }
        }
    }

    func useADifferentNumber() {
        guard !isBusy else { return }
        authTask?.cancel()
        stage = .enterPhone
        code = ""
        normalizedPhoneNumber = nil
        errorMessage = nil
    }
}

struct PhoneAuthFlowView: View {
    private enum Field { case phone, code }

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = PhoneAuthModel()
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            ZStack {
                BrandScreenBackground()

                ScrollView {
                    VStack(spacing: 26) {
                        Spacer(minLength: 54)
                        BrandWordmark()

                        Text("Get every photo of you.")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.ink)

                        Text("Photos your friends took of you on their phones, brought to your phone automatically.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)

                        PremiumCard {
                            switch model.stage {
                            case .enterPhone: phoneEntry
                            case .enterCode: codeEntry
                            }
                        }
                        .padding(.horizontal, 20)

                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                        }

                        Spacer(minLength: 44)
                    }
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .task { model.configure(env: env, session: session) }
        }
    }

    private var phoneEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Mobile number", systemImage: "iphone")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)

            HStack(spacing: 10) {
                Menu {
                    ForEach(PhoneCountry.supported) { country in
                        Button("\(country.name)  \(country.callingCode)") {
                            model.selectedCountry = country
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.selectedCountry.regionCode).bold()
                        Text(model.selectedCountry.callingCode).bold()
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(Theme.sunset)
                    .padding(.horizontal, 12)
                    .frame(height: 60)
                    .background(Theme.peach.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                TextField("Phone number", text: $model.phoneNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focusedField, equals: .phone)
                    .padding()
                    .frame(height: 60)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button {
                // Set busy state first; dismissing the keyboard must not consume
                // the user's only visible feedback for this tap.
                model.beginSendCode()
                focusedField = nil
            } label: {
                HStack(spacing: 9) {
                    if model.isBusy {
                        ProgressView().tint(.white)
                        Text("Sending Code…")
                    } else {
                        Image(systemName: "message.fill")
                        Text("Send Code")
                    }
                }
            }
            .buttonStyle(MyPicsTubePrimaryButtonStyle())
            .disabled(model.isBusy || model.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(model.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.sunset)

            if let normalized = model.normalizedPhoneNumber {
                Text("Enter the 6-digit code").font(.headline)
                Text("Sent to \(normalized)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter the 6-digit code").font(.headline)
            }

            TextField("6-digit code", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .code)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit().bold())
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            Button {
                model.beginVerifyCode()
                focusedField = nil
            } label: {
                HStack(spacing: 9) {
                    if model.isBusy {
                        ProgressView().tint(.white)
                        Text("Verifying…")
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Verify")
                    }
                }
            }
            .buttonStyle(MyPicsTubePrimaryButtonStyle())
            .disabled(model.isBusy || model.code.count < 6)
            .opacity(model.code.count < 6 ? 0.55 : 1)

            Button("Use a different number") {
                focusedField = nil
                model.useADifferentNumber()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.sky)
            .disabled(model.isBusy)
        }
    }
}

#Preview {
    PhoneAuthFlowView()
        .environmentObject(AppEnvironment.dev())
        .environmentObject(AppSession())
}
