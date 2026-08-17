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

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
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
        Form {
            Section("Add a person") {
                HStack {
                    Menu {
                        ForEach(PhoneCountry.supported) { value in
                            Button("\(value.name)  \(value.callingCode)") { country = value }
                        }
                    } label: {
                        Text("\(country.regionCode) \(country.callingCode)")
                    }
                    TextField("Phone number", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                }
                Button { showContacts = true } label: {
                    Label("Choose from Contacts", systemImage: "person.crop.circle.badge.plus")
                }
            }

            Section {
                Button {
                    Task { await sendInvite() }
                } label: {
                    Group { if isSending { ProgressView() } else { Label("Send Invite", systemImage: "paperplane.fill") } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || phone.isEmpty)

                if let message { Text(message).foregroundStyle(.secondary) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }

            if !statuses.isEmpty {
                Section("Invitations") {
                    ForEach(statuses) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.phoneNumber)
                                Text(row.delivery == "in_app" ? "In-app" : "SMS")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(row.status.capitalized)
                                .font(.caption).bold()
                        }
                    }
                }
            }

            Section("How it works") {
                Text("SnapLoop checks the phone number on the server. Existing users receive a pending in-app event invitation, so no SMS is needed. A person without a SnapLoop account gets the SMS invite link instead.")
                Text("Nobody is silently added to an event. The recipient accepts the invitation before membership and face matching begin.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Invite by Phone")
        .task { await refreshStatuses() }
        .sheet(isPresented: $showContacts) {
            ContactPhonePicker { selected in
                phone = selected
                showContacts = false
            }
        }
        .sheet(isPresented: $showMessage) {
            MessageInviteComposer(recipients: [smsRecipient], body: messageBody)
        }
    }

    @MainActor
    private func sendInvite() async {
        guard event.status == .active else {
            errorMessage = "This event is not accepting new invitations. Reopen it first if you're the organizer."
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
            phone = normalized
            switch delivery.kind {
            case .inApp:
                message = "Invitation delivered inside SnapLoop. No SMS was sent."
            case .sms:
                smsRecipient = normalized
                guard MFMessageComposeViewController.canSendText() else {
                    message = "This person does not have SnapLoop yet. Use Share Invite to send \(inviteURL.absoluteString)."
                    await refreshStatuses()
                    return
                }
                message = "This person does not have SnapLoop yet. Send the prepared SMS invitation."
                showMessage = true
            }
            await refreshStatuses()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    @MainActor
    private func refreshStatuses() async {
        do { statuses = try await EventInviteClient.list(eventId: event.id) }
        catch { /* Status display is non-critical; sending can still surface its own error. */ }
    }
}
