import SwiftUI

@MainActor
final class PhoneAuthModel: ObservableObject {
    enum Stage { case enterPhone, enterCode(verificationId: String) }

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
                    let created = User(id: uid, phoneNumber: canonicalPhone, displayName: nil,
                                       hasFaceProfile: false, createdAt: env.clock.now())
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
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
                Spacer()
                Spacer()
            }
            .task { model.configure(env: env, session: session) }
        }
    }

    private var phoneEntry: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Country / region")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Picker("Country / region", selection: $model.selectedCountry) {
                    ForEach(PhoneCountry.supported) { country in
                        Text("\(country.name)  \(country.callingCode)").tag(country)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 10) {
                Text(model.selectedCountry.callingCode)
                    .font(.body.monospacedDigit()).bold()
                    .foregroundStyle(Theme.coral)
                    .padding(.leading, 14)
                Divider().frame(height: 28)
                TextField("Phone number", text: $model.phoneNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding(.vertical, 15).padding(.trailing, 14)
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Text("Country defaults from your iPhone region. You can still paste a full +country-code number.")
                .font(.caption).foregroundStyle(.secondary)

            Button { Task { await model.sendCode() } } label: {
                Group { if model.isBusy { ProgressView() } else { Text("Send Code") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.coral).controlSize(.large)
            .disabled(model.isBusy || model.phoneNumber.isEmpty)
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 12) {
            Text(model.normalizedPhoneNumber.map { "Enter the code sent to \($0)" } ?? "Enter the code we sent you")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("6-digit code", text: $model.code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .multilineTextAlignment(.center).font(.title2).bold().padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Button { Task { await model.verifyCode() } } label: {
                Group { if model.isBusy { ProgressView() } else { Text("Verify") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.coral).controlSize(.large)
            .disabled(model.isBusy || model.code.count < 4)

            Button("Use a different number") { model.useADifferentNumber() }.font(.footnote)
        }
    }
}

#Preview {
    PhoneAuthFlowView().environmentObject(AppEnvironment.dev()).environmentObject(AppSession())
}
