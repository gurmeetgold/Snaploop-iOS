import SwiftUI

@MainActor
final class PhoneAuthModel: ObservableObject {
    enum Stage {
        case enterPhone
        case enterCode(verificationId: String)
    }

    @Published var stage: Stage = .enterPhone
    @Published var phoneNumber = ""
    @Published var code = ""
    @Published var isBusy = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func sendCode() async {
        guard let env else { return }
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 8 else {
            errorMessage = AppError.invalidPhoneNumber.userMessage
            return
        }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let verificationId = try await env.auth.startPhoneVerification(phoneNumber: trimmed)
            stage = .enterCode(verificationId: verificationId)
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.unknown("\(error)").userMessage
        }
    }

    func verifyCode() async {
        guard let env, let session, case .enterCode(let verificationId) = stage else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let uid = try await env.auth.confirmVerification(verificationId: verificationId, code: code)
            // NOTE: locally-constructed profile. Firestore-backed UserDirectory
            // is the next wiring step — until then, signing in proves identity
            // via Firebase Auth but doesn't persist a profile beyond that.
            session.user = User(
                id: uid,
                phoneNumber: phoneNumber.trimmingCharacters(in: .whitespaces),
                displayName: nil,
                hasFaceProfile: false,
                createdAt: Date())
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.unknown("\(error)").userMessage
        }
    }

    func useADifferentNumber() {
        stage = .enterPhone
        code = ""
        errorMessage = nil
    }
}

/// Registration: phone number → OTP → signed in. Wired to `AppEnvironment.auth`
/// (real Firebase Auth when `AppEnvironment.live()` is active, a stub otherwise)
/// — see `AppEnvironment.live()` for exactly what's real today.
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
            TextField("Phone number", text: $model.phoneNumber)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Button {
                Task { await model.sendCode() }
            } label: {
                Group {
                    if model.isBusy { ProgressView() } else { Text("Send Code") }
                }
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
            Text("Enter the code we sent you")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("6-digit code", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title2).bold()
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Button {
                Task { await model.verifyCode() }
            } label: {
                Group {
                    if model.isBusy { ProgressView() } else { Text("Verify") }
                }
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
