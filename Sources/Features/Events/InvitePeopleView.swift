import ContactsUI
import MessageUI
import SwiftUI

struct ContactPhonePicker: UIViewControllerRepresentable {
    let onPhone: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPhonePicker
        init(parent: ContactPhonePicker) { self.parent = parent }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            if let phone = contactProperty.value as? CNPhoneNumber {
                parent.onPhone(phone.stringValue)
            }
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {}
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
    @Environment(\.dismiss) private var dismiss

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let parent: MessageInviteComposer
        init(parent: MessageInviteComposer) { self.parent = parent }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
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

/// MVP organizer-assisted invite. The HTTPS token is stable: an installed app
/// can route it into the exact Join screen; otherwise Firebase Hosting can show
/// the download/landing experience. Existing-account lookup + silent in-app
/// delivery intentionally remains server-authoritative rather than scraping the
/// users collection from a client.
struct InvitePeopleView: View {
    let event: Event
    @State private var phone = ""
    @State private var showContacts = false
    @State private var showMessage = false
    @State private var errorMessage: String?

    private var token: InviteToken { InviteToken(event.inviteToken) ?? InviteToken(unchecked: event.inviteToken) }
    private var inviteURL: URL { InviteLink.url(forToken: token) }
    private var messageBody: String {
        "Join \(event.name) on SnapLoop: \(inviteURL.absoluteString)"
    }

    var body: some View {
        Form {
            Section("Add a person") {
                TextField("Phone number", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)

                Button {
                    showContacts = true
                } label: {
                    Label("Choose from Contacts", systemImage: "person.crop.circle.badge.plus")
                }
            }

            Section {
                Button {
                    let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.filter(\.isNumber).count >= 8 else {
                        errorMessage = "Enter or choose a valid phone number."
                        return
                    }
                    guard MFMessageComposeViewController.canSendText() else {
                        errorMessage = "Messages is not available on this device. Use Share Link instead."
                        return
                    }
                    errorMessage = nil
                    showMessage = true
                } label: {
                    Label("Send Invite", systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Section("How it works") {
                Text("The invite always points to this exact trip. If SnapLoop is already installed, the app handles the trip link. Otherwise the web landing page can send the person to the App Store and preserve the invite token.")
                Text("For the commercial flow, SnapLoop will check the phone number server-side first: existing users get an in-app invitation; non-users get SMS. We do not auto-join anyone without acceptance.")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Invite by Phone")
        .sheet(isPresented: $showContacts) {
            ContactPhonePicker { selected in
                phone = selected
                showContacts = false
            }
        }
        .sheet(isPresented: $showMessage) {
            MessageInviteComposer(recipients: [phone], body: messageBody)
        }
    }
}
