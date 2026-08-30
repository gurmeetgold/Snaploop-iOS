import ContactsUI
import MessageUI
import SwiftUI

struct ContactPhonePicker: UIViewControllerRepresentable {
    let onPhone: (String) -> Void

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPhonePicker
        init(parent: ContactPhonePicker) { self.parent = parent }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            if let phone = contactProperty.value as? CNPhoneNumber { parent.onPhone(phone.stringValue) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == 'phoneNumbers'")
        return picker
    }
    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}
}

struct MessageInviteComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onResult: (MessageComposeResult) -> Void

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let parent: MessageInviteComposer
        init(parent: MessageInviteComposer) { self.parent = parent }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            parent.onResult(result)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = recipients
        controller.body = body
        return controller
    }
    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}
}

struct InvitePeopleView: View {
    let event: Event
    @State private var country: PhoneCountry = .localeDefault
    @State private var phone = ""
    @State private var smsRecipient = ""
    @State private var showContacts = false
    @State private var showMessage = false
    @State private var isSending = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var statuses: [EventInviteStatusRow] = []

    private var token: InviteToken { InviteToken(event.inviteToken) ?? InviteToken(unchecked: event.inviteToken) }
    private var inviteURL: URL { InviteLink.url(forToken: token) }
    private var messageBody: String { "Join \(event.name) on SnapLoop: \(inviteURL.absoluteString)" }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandMark(size: 56)
                    Text("Invite by Phone")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text("Invite someone directly, or choose a number from your contacts.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    PremiumCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Add a person", systemImage: "person.badge.plus")
                                .font(.headline).foregroundStyle(Theme.ink)
                            HStack(spacing: 10) {
                                Menu {
                                    ForEach(PhoneCountry.supported) { value in
                                        Button("\(value.name)  \(value.callingCode)") {
                                            country = value
                                            phone = localDisplayNumber(phone, for: value)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(country.regionCode).bold()
                                        Text(country.callingCode).bold()
                                        Image(systemName: "chevron.down").font(.caption2)
                                    }
                                    .foregroundStyle(Theme.sunset)
                                    .padding(.horizontal, 11)
                                    .frame(height: 58)
                                    .background(Theme.peach.opacity(0.18), in: RoundedRectangle(cornerRadius: 15))
                                }

                                TextField("Phone number", text: $phone)
                                    .keyboardType(.phonePad)
                                    .textContentType(.telephoneNumber)
                                    .padding()
                                    .frame(height: 58)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15))
                                    .onChange(of: phone) { _, newValue in
                                        let local = localDisplayNumber(newValue, for: country)
                                        if local != newValue { phone = local }
                                    }
                            }

                            Button { showContacts = true } label: {
                                Label("Choose from Contacts", systemImage: "person.crop.circle.badge.plus")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.aqua)
                            .background(Theme.aqua.opacity(0.11), in: RoundedRectangle(cornerRadius: 15))
                        }
                    }

                    Button {
                        guard !isSending else { return }
                        Task { await sendInvite() }
                    } label: {
                        HStack {
                            if isSending { ProgressView().tint(.white) }
                            else { Image(systemName: "paperplane.fill") }
                            Text(isSending ? "Sending…" : "Send Invite")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    .disabled(isSending || phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)

                    if let message {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(.green).multilineTextAlignment(.center)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    if !statuses.isEmpty { invitationStatusCard }
                    howItWorks
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Invite by Phone")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatuses() }
        .sheet(isPresented: $showContacts) {
            ContactPhonePicker { selected in
                phone = localDisplayNumber(selected, for: country)
                errorMessage = nil
                showContacts = false
            }
        }
        .sheet(isPresented: $showMessage) {
            MessageInviteComposer(recipients: [smsRecipient], body: messageBody) { result in
                switch result {
                case .sent:
                    message = "SMS invitation sent."
                    errorMessage = nil
                case .failed:
                    message = nil
                    errorMessage = "The SMS invitation could not be sent."
                case .cancelled:
                    message = "SMS invitation was not sent."
                @unknown default:
                    message = nil
                }
                Task { await refreshStatuses() }
            }
        }
    }

    private var invitationStatusCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Invitations", systemImage: "envelope.open.fill")
                    .font(.headline).foregroundStyle(Theme.ink)
                ForEach(statuses) { row in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill((row.delivery == "in_app" ? Theme.aqua : Theme.sunset).opacity(0.12))
                            Image(systemName: row.delivery == "in_app" ? "app.badge.fill" : "message.fill")
                                .font(.caption).foregroundStyle(row.delivery == "in_app" ? Theme.aqua : Theme.sunset)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.phoneNumber).font(.subheadline.weight(.semibold))
                            Text(row.delivery == "in_app" ? "In-app invitation" : "SMS invitation")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.status.capitalized)
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Theme.peach.opacity(0.22), in: Capsule())
                    }
                    if row.id != statuses.last?.id { Divider() }
                }
            }
        }
    }

    private var howItWorks: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("How it works", systemImage: "sparkles")
                    .font(.headline).foregroundStyle(Theme.ink)
                Text("Enter a phone number or choose a contact. Existing SnapLoop users receive the invitation directly in the app. If they are not on SnapLoop yet, you can send them an SMS invite link.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("They join only after accepting the invitation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func localDisplayNumber(_ raw: String, for selectedCountry: PhoneCountry) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return raw }
        let digits = trimmed.filter(\.isNumber)
        let callingDigits = selectedCountry.callingCode.filter(\.isNumber)
        guard !callingDigits.isEmpty, digits.hasPrefix(callingDigits) else { return raw }
        return String(digits.dropFirst(callingDigits.count))
    }

    @MainActor
    private func sendInvite() async {
        guard !isSending else { return }
        guard event.status == .active else {
            errorMessage = "This Event is not accepting new invitations. Reopen it first if you're the organizer."
            return
        }
        guard let normalized = PhoneNumberNormalizer.e164(localInput: phone, country: country) else {
            errorMessage = "Enter or choose a valid phone number."
            return
        }
        isSending = true
        message = nil
        errorMessage = nil
        defer { isSending = false }

        do {
            let delivery = try await EventInviteClient.invite(eventId: event.id, phoneNumber: normalized)
            switch delivery.kind {
            case .inApp:
                message = "Invitation delivered in SnapLoop."
            case .sms:
                smsRecipient = normalized
                guard MFMessageComposeViewController.canSendText() else {
                    message = "This person is not on SnapLoop yet. Use Share Invite to send the Event link."
                    await refreshStatuses()
                    return
                }
                message = "SMS invitation ready to send."
                showMessage = true
            }
            phone = localDisplayNumber(phone, for: country)
            await refreshStatuses()
        } catch {
            errorMessage = EventInviteClient.userMessage(for: error)
        }
    }

    @MainActor
    private func refreshStatuses() async {
        do { statuses = try await EventInviteClient.list(eventId: event.id) }
        catch { }
    }
}
