import CoreLocation
import MapKit
import SwiftUI

struct LocalExpert: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    let phone: String?
    let url: URL?
    let coordinate: CLLocationCoordinate2D
    let miles: Double
    let mapItem: MKMapItem

    static func == (lhs: LocalExpert, rhs: LocalExpert) -> Bool { lhs.id == rhs.id }
}

/// Finds Phantom Screens businesses near a ZIP or postal code with Apple Maps search.
struct DealerView: View {
    @Binding var zip: String
    @Binding var selection: LocalExpert?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var results: [LocalExpert] = []
    @State private var searching = false
    @State private var message: String?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("ZIP or postal code", text: $zip)
                        .textContentType(.postalCode)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button {
                        Task { await search() }
                    } label: {
                        if searching { ProgressView() } else { Text("Search") }
                    }
                    .disabled(zip.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
            }

            if !results.isEmpty {
                Section {
                    Map(position: $camera) {
                        ForEach(results) { expert in
                            Marker(expert.name, coordinate: expert.coordinate)
                        }
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                }

                Section("Near \(zip)") {
                    ForEach(results) { expert in
                        ExpertRow(expert: expert, selected: selection == expert) {
                            selection = expert
                            dismiss()
                        } call: {
                            if let phone = expert.phone, let url = Self.telURL(phone) { openURL(url) }
                        } directions: {
                            expert.mapItem.openInMaps()
                        } website: {
                            if let url = expert.url { openURL(url) }
                        }
                    }
                }
            } else if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }

            Section {
                Link(destination: URL(string: "tel:18887426866")!) {
                    Label("Call Phantom: 1-888-PHANTOM (742-6866)", systemImage: "phone")
                }
                Link(destination: URL(string: "https://www.phantomscreens.com/")!) {
                    Label("phantomscreens.com", systemImage: "safari")
                }
            } header: {
                Text("Rather talk to someone now?")
            } footer: {
                Text("Every Phantom screen is professionally installed and backed by a Limited Lifetime Warranty. Results come from Apple Maps and may not list every authorized distributor.")
            }
        }
        .navigationTitle("Local Phantom expert")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if results.isEmpty, !zip.isEmpty { await search() }
        }
    }

    private func search() async {
        let query = zip.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        message = nil
        defer { searching = false }

        guard let placemark = try? await CLGeocoder().geocodeAddressString(query).first,
              let origin = placemark.location else {
            results = []
            message = "Couldn't find that ZIP or postal code."
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "Phantom Screens"
        request.region = MKCoordinateRegion(center: origin.coordinate,
                                            latitudinalMeters: 160_000, longitudinalMeters: 160_000)
        guard let response = try? await MKLocalSearch(request: request).start() else {
            results = []
            message = "No Phantom Screens locations found nearby. Call 1-888-PHANTOM and they'll connect you."
            return
        }

        results = response.mapItems
            .filter { ($0.name ?? "").localizedCaseInsensitiveContains("phantom") }
            .compactMap { item -> LocalExpert? in
                guard let location = item.placemark.location else { return nil }
                return LocalExpert(
                    name: item.name ?? "Phantom Screens",
                    address: item.placemark.title ?? "",
                    phone: item.phoneNumber,
                    url: item.url,
                    coordinate: location.coordinate,
                    miles: location.distance(from: origin) / 1609.34,
                    mapItem: item
                )
            }
            .sorted { $0.miles < $1.miles }

        if results.isEmpty {
            message = "No Phantom Screens locations found nearby. Call 1-888-PHANTOM and they'll connect you."
        } else {
            camera = .automatic
        }
    }

    static func telURL(_ phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return URL(string: "tel:\(digits)")
    }
}

private struct ExpertRow: View {
    let expert: LocalExpert
    let selected: Bool
    let choose: () -> Void
    let call: () -> Void
    let directions: () -> Void
    let website: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(expert.name).font(.headline)
                    Text(expert.address).font(.subheadline).foregroundStyle(.secondary)
                    Text(String(format: "%.0f mi away", expert.miles))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 8) {
                if expert.phone != nil {
                    action("phone.fill", "Call", call)
                }
                action("map.fill", "Directions", directions)
                if expert.url != nil {
                    action("safari.fill", "Website", website)
                }
                Spacer()
                Button("Choose", action: choose)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
        }
        .padding(.vertical, 4)
    }

    private func action(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).frame(width: 36, height: 32)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }
}
