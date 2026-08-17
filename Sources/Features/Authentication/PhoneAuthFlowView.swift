import SwiftUI

@MainActor
final class PhoneAuthModel: ObservableObject {
    enum Stage {
        case enterPhone
        case enterCode(verificationId: String)
    }

    @Published var stage: Stage = .enterPhone
    @Published var selectedCountry: PhoneCountry = .localeDefault
    @Published var phoneNumber = ""
    @Published var normalizedPhoneNumber: String?
    @Published var code = ""
    @Published var isBusy = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    func sendCode() async {
        guard let env else { return }
        guard let e164 = PhoneNumberNormalizer.e164(localInput: phoneNumber, country: selectedCountry) else {
            errorMessage = AppError.invalidPhoneNumber.userMessage
            return
        }
        normalizedPhoneNumber = e164
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let verificationId = try await env.auth.startPhoneVerification(phoneNumber: e164)
            stage = .enterCode(verificationId: verificationId)
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.unknown("\(error)").userMessage
        }
    }

    func verifyCode() async {
        guard let env, let session, case .enterCode(let verificationId) = stage else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let uid = try await env.auth.confirmVerification(verificationId: verificationId, code: code)
            let canonicalPhone = normalizedPhoneNumber
                ?? PhoneNumberNormalizer.e164(localInput: phoneNumber, country: selectedCountry)
                ?? phoneNumber

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
                } else {
                    throw error
                }
            }

            let faceProfile = try await env.faceProfiles.load(userId: uid)
            var reconciledUser = user
            if (faceProfile != nil) != user.hasFaceProfile {
                reconciledUser.hasFaceProfile = faceProfile != nil
                try await env.users.save(reconciledUser)
            }

            // Assign session state only after all reads succeed, preventing a
            // half-switched account from inheriting the previous account's face
            // profile or active event on a shared device.
            session.beginAuthenticatedSession(user: reconciledUser, faceProfile: faceProfile)
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.unknown("\(error)").userMessage
        }
    }

    func useADifferentNumber() {
        stage = .enterPhone
        code = ""
        normalizedPhoneNumber = nil
        errorMessage = nil
    }
}

struct PhoneAuthFlowView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = PhoneAuthModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "camera.aperture")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.coralGradient)
                Text("SnapLoop").font(.largeTitle).bold().foregroundStyle(Theme.ink)
                Text("Get every photo of you from everyone's camera — automatically.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Group {
                    switch model.stage {
                    case .enterPhone: phoneEntry
                    case .enterCode: codeEntry
                    }
                }
                .padding(.horizontal, 24)

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
                Spacer()
            }
            .task { model.configure(env: env, session: session) }
        }
    }

    private var phoneEntry: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(PhoneCountry.supported) { country in
                        Button("\(country.name)  \(country.callingCode)") {
                            model.selectedCountry = country
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.selectedCountry.regionCode)
                        Text(model.selectedCountry.callingCode)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 15)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }

                TextField("Phone number", text: $model.phoneNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            Text("Country defaults from your iPhone region. You can also paste a full +country-code number.")
                .font(.caption).foregroundStyle(.secondary)

            Button { Task { await model.sendCode() } } label: {
                Group { if model.isBusy { ProgressView() } else { Text("Send Code") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.coral)
            .controlSize(.large)
            .disabled(model.isBusy || model.phoneNumber.isEmpty)
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 12) {
            if let normalized = model.normalizedPhoneNumber {
                Text("Enter the code sent to \(normalized)")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Enter the code we sent you")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            TextField("6-digit code", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title2).bold()
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Button { Task { await model.verifyCode() } } label: {
                Group { if model.isBusy { ProgressView() } else { Text("Verify") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.coral)
            .controlSize(.large)
            .disabled(model.isBusy || model.code.count < 4)

            Button("Use a different number") { model.useADifferentNumber() }
                .font(.footnote)
        }
    }
}

#Preview {
    PhoneAuthFlowView()
        .environmentObject(AppEnvironment.dev())
        .environmentObject(AppSession())
}
