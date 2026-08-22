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
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }
    func sendCode() async {
        guard let env else { return }
        guard let e164 = PhoneNumberNormalizer.e164(localInput: phoneNumber, country: selectedCountry) else { errorMessage = AppError.invalidPhoneNumber.userMessage; return }
        normalizedPhoneNumber = e164; isBusy = true; errorMessage = nil; defer { isBusy = false }
        do { stage = .enterCode(verificationId: try await env.auth.startPhoneVerification(phoneNumber: e164)) }
        catch let error as AppError { errorMessage = error.userMessage }
        catch { errorMessage = AppError.unknown("\(error)").userMessage }
    }
    func verifyCode() async {
        guard let env, let session, case .enterCode(let verificationId) = stage else { return }
        isBusy = true; errorMessage = nil; defer { isBusy = false }
        do {
            let uid = try await env.auth.confirmVerification(verificationId: verificationId, code: code)
            let canonicalPhone = normalizedPhoneNumber ?? PhoneNumberNormalizer.e164(localInput: phoneNumber, country: selectedCountry) ?? phoneNumber
            let user: User
            do { user = try await env.users.fetch(userId: uid) }
            catch let error as AppError {
                if case .backend(let backendCode, _) = error, backendCode == "user_not_found" {
                    let created = User(id: uid, phoneNumber: canonicalPhone, displayName: nil, hasFaceProfile: false, createdAt: env.clock.now())
                    try await env.users.save(created); user = created
                } else { throw error }
            }

            // Enter the authenticated UI immediately after identity is resolved.
            // Face-profile hydration is deliberately deferred by RootView so it
            // never holds the user on the login screen.
            session.beginAuthenticatedSession(user: user, faceProfile: nil)
        } catch let error as AppError { errorMessage = error.userMessage }
        catch { errorMessage = AppError.unknown("\(error)").userMessage }
    }
    func useADifferentNumber() { stage = .enterPhone; code = ""; normalizedPhoneNumber = nil; errorMessage = nil }
}

struct PhoneAuthFlowView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = PhoneAuthModel()
    var body: some View {
        NavigationStack {
            ZStack {
                BrandScreenBackground()
                ScrollView {
                    VStack(spacing: 26) {
                        Spacer(minLength: 72)
                        BrandWordmark()
                        Text("Get every photo of you.").font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text("Photos your friends took of you on their phones, brought to your phone automatically.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 36)
                        PremiumCard { Group { switch model.stage { case .enterPhone: phoneEntry; case .enterCode: codeEntry } } }.padding(.horizontal, 20)
                        if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 28) }
                        Spacer(minLength: 56)
                    }
                }
            }.task { model.configure(env: env, session: session) }
        }
    }

    private var phoneEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Mobile number", systemImage: "iphone").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            HStack(spacing: 10) {
                Menu {
                    ForEach(PhoneCountry.supported) { country in Button("\(country.name)  \(country.callingCode)") { model.selectedCountry = country } }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.selectedCountry.regionCode).bold(); Text(model.selectedCountry.callingCode).bold(); Image(systemName: "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(Theme.sunset).padding(.horizontal, 12).frame(height: 60)
                    .background(Theme.peach.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                TextField("Phone number", text: $model.phoneNumber).keyboardType(.phonePad).textContentType(.telephoneNumber).padding().frame(height: 60)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Button { Task { await model.sendCode() } } label: {
                HStack { if model.isBusy { ProgressView().tint(.white) } else { Image(systemName: "message.fill"); Text("Send Code") } }
                    .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
            }
            .buttonStyle(.plain).foregroundStyle(.white).background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(model.isBusy || model.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(model.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill").font(.system(size: 34)).foregroundStyle(Theme.sunset)
            if let normalized = model.normalizedPhoneNumber { Text("Enter the 6-digit code").font(.headline); Text("Sent to \(normalized)").font(.subheadline).foregroundStyle(.secondary) }
            else { Text("Enter the 6-digit code").font(.headline) }
            TextField("6-digit code", text: $model.code).keyboardType(.numberPad).textContentType(.oneTimeCode).multilineTextAlignment(.center).font(.title2.monospacedDigit().bold()).padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            Button { Task { await model.verifyCode() } } label: { HStack { if model.isBusy { ProgressView().tint(.white) } else { Image(systemName: "checkmark.circle.fill"); Text("Verify") } }.font(.headline).frame(maxWidth: .infinity).frame(height: 54) }
                .buttonStyle(.plain).foregroundStyle(.white).background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18)).disabled(model.isBusy || model.code.count < 4).opacity(model.code.count < 4 ? 0.55 : 1)
            Button("Use a different number") { model.useADifferentNumber() }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.sky)
        }
    }
}

#Preview { PhoneAuthFlowView().environmentObject(AppEnvironment.dev()).environmentObject(AppSession()) }
