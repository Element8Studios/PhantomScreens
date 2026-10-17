import SwiftUI
import UIKit

/// Review Your Order, in two pages:
/// 1. What you chose: a snapshot of the screen in your opening and every
///    selection. Tapping a selection goes back to Customize on that option.
/// 2. Request a Quote: your details and local expert, handed to Mail,
///    Messages or any share target.
/// No prices: they vary by region, so the local expert quotes.
struct ReviewView: View {
    @ObservedObject var session: PhantomSession
    @ObservedObject var store: DesignStore
    let unit: LengthUnit
    /// Back to Customize on one option.
    let onEdit: (OptionStep) -> Void
    @Environment(\.dismiss) private var dismiss

    @AppStorage("quote.name") private var name = ""
    @AppStorage("quote.email") private var email = ""
    @AppStorage("quote.phone") private var phone = ""
    @AppStorage("quote.zip") private var zip = ""
    @State private var openingName = ""
    @State private var contact: ContactMethod = .call
    @State private var attachPhotos = true
    @State private var notes = ""
    @State private var expert: LocalExpert?
    @State private var sharePayload: SharePayload?
    @State private var sent = false
    /// A snapshot of the screen in the opening, taken as the review opens.
    @State private var preview: UIImage?

    enum ContactMethod: String, CaseIterable, Identifiable {
        case call = "Call", text = "Text", email = "Email"
        var id: String { rawValue }
    }

    private var canSend: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (!email.isEmpty || !phone.isEmpty)
    }

    /// Photos the user took, or the snapshot if they took none.
    private var attachments: [UIImage] {
        if !session.photoData.isEmpty { return session.photos }
        return preview.map { [$0] } ?? []
    }

    var body: some View {
        NavigationStack {
            if sent {
                SentView(expertName: expert?.name) { dismiss() }
            } else {
                summary
            }
        }
        .task {
            if preview == nil { preview = await session.previewSnapshot() }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items) { completed in
                sharePayload = nil
                if completed { finish() }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Page 1: your order

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let preview {
                            Image(uiImage: preview).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.06)
                                .overlay(ProgressView())
                        }
                    }
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .clipped()

                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.config.product.title).font(.headline)
                        Text("\(Length.size(width: session.config.width, height: session.config.height, unit: unit)), measured in AR")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(spacing: 0) {
                    let items = session.config.lineItems(unit: unit)
                    ForEach(items) { item in
                        selectionRow(item)
                        if item.id != items.last?.id {
                            Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 14)
                        }
                    }
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Tap a selection to change it. Pricing varies by region: your local Phantom expert prepares your quote and confirms final measurements on site.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    requestForm
                } label: {
                    Text("Request a Quote")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .navigationTitle("Review Your Order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func selectionRow(_ item: LineItem) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.caption).foregroundStyle(.secondary)
                Text(item.value).font(.subheadline).foregroundStyle(.white)
            }
            Spacer()
            if let tag = item.tag {
                Text(tag.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tag == .included ? Color.secondary : Color.phantomCyan)
            }
            if item.step != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())

        if let step = item.step {
            Button { onEdit(step) } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("Change this option")
        } else {
            row
        }
    }

    // MARK: - Page 2: request a quote

    private var requestForm: some View {
        Form {
            Section {
                TextField("Opening name, e.g. Back patio door", text: $openingName)
            } footer: {
                Text("Helps your expert if you send more than one opening.")
            }

            Section("Your details") {
                TextField("Full name", text: $name)
                    .textContentType(.name)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Phone", text: $phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                TextField("ZIP or postal code", text: $zip)
                    .textContentType(.postalCode)
                Picker("Best way to reach you", selection: $contact) {
                    ForEach(ContactMethod.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section {
                NavigationLink {
                    DealerView(zip: $zip, selection: $expert)
                } label: {
                    LabeledContent("Local Phantom expert") {
                        Text(expert?.name ?? "Find by ZIP")
                    }
                }
            } footer: {
                Text("Phantom Screens are sold and professionally installed by authorized distributors.")
            }

            Section {
                Toggle("Attach pictures (\(attachments.count))", isOn: $attachPhotos)
                    .disabled(attachments.isEmpty)
                TextField("Notes for your expert", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section {
                Button {
                    sharePayload = SharePayload(items: shareItems())
                } label: {
                    Text("Send to My Local Expert")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canSend)
            } footer: {
                if !canSend {
                    Text("Add your name and an email or phone number.")
                }
            }
        }
        .navigationTitle("Request a Quote")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var resolvedOpeningName: String {
        let trimmed = openingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        switch session.config.product.category {
        case .door: return "Doorway"
        case .window: return "Window"
        case .outdoor: return "Outdoor space"
        }
    }

    private func shareItems() -> [Any] {
        let c = session.config
        var lines = [
            "Quote request: Phantom Screens",
            "",
            "Opening: \(resolvedOpeningName)"
        ]
        for item in c.lineItems(unit: .inches) {
            var line = "\(item.label): \(item.value)"
            if let tag = item.tag { line += " (\(tag.label.lowercased()))" }
            lines.append(line)
        }
        lines += [
            "Size in centimeters: \(Length.size(width: c.width, height: c.height, unit: .centimeters))",
            "",
            "Name: \(name)"
        ]
        if !email.isEmpty { lines.append("Email: \(email)") }
        if !phone.isEmpty { lines.append("Phone: \(phone)") }
        if !zip.isEmpty { lines.append("ZIP/postal code: \(zip)") }
        lines.append("Best way to reach me: \(contact.rawValue)")
        if let note = c.customColorNote { lines += ["", note] }
        if let expert { lines.append("Local expert: \(expert.name)") }
        if !notes.isEmpty { lines += ["", "Notes: \(notes)"] }
        lines += ["", "Sent from the Phantom Screens app. Measured in AR; final measurements to be confirmed on site."]

        var items: [Any] = [lines.joined(separator: "\n")]
        if attachPhotos { items += attachments }
        return items
    }

    private func finish() {
        store.add(name: resolvedOpeningName, config: session.config, photo: session.photoData.last.flatMap(UIImage.init(data:)) ?? preview)
        withAnimation { sent = true }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SentView: View {
    let expertName: String?
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quote request sent").font(.largeTitle.bold())
                    Text("\(expertName ?? "Your local Phantom expert") will get in touch to walk through your options and prepare a quote for your review.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    StepRow(number: 1, title: "Your expert reaches out", detail: "They review your design, size and photos.")
                    StepRow(number: 2, title: "In-home consultation", detail: "Final measurements, color swatches and mesh samples.")
                    StepRow(number: 3, title: "Professional installation", detail: "Backed by a Limited Lifetime Warranty.")
                }
                Text("Saved to Designs.").font(.footnote).foregroundStyle(.secondary)
                Button(action: onDone) {
                    Text("Back to My Space").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
            .padding(24)
        }
        .navigationBarBackButtonHidden()
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
