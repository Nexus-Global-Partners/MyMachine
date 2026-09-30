import CoreLocation
import DailyMacCore
import SwiftUI

enum SolarPreferences {
    static let key = "historySolarLocation"
    static func decode(_ string: String) -> SolarLocation? {
        guard let data = string.data(using: .utf8),
              let location = try? JSONDecoder().decode(SolarLocation.self, from: data), location.isValid else { return nil }
        return location
    }
}

struct SolarSettingsView: View {
    @AppStorage(SolarPreferences.key) private var saved = ""
    @State private var city = ""
    @State private var searching = false
    @State private var message: String?
    @State private var matches: [SolarLocation] = []
    @State private var geocoder = CLGeocoder()

    var body: some View {
        Section("Day & night in history") {
            HStack {
                TextField("City and country", text: $city).onSubmit { findCity() }
                Button(searching ? "Finding…" : "Find city") { findCity() }
                    .disabled(searching || city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                Button("Use \(match.name)") {
                    if let data = try? JSONEncoder().encode(match), let value = String(data: data, encoding: .utf8) {
                        saved = value; matches = []; message = nil
                    }
                }
            }
            if let location = SolarPreferences.decode(saved) {
                HStack {
                    Text(location.name)
                    Spacer()
                    Button("Turn off") { saved = ""; matches = []; message = nil }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Find city sends only your search to Apple's geocoder. The chosen city stays on this Mac; no location tracking. Day, civil twilight and night are calculated locally for each date. Times are approximate and do not account for weather or terrain. The saved city applies to all history; update it when travelling.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func findCity() {
        let query = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searching, !query.isEmpty else { return }
        searching = true; message = nil; matches = []
        geocoder.geocodeAddressString(query) { placemarks, error in
            DispatchQueue.main.async {
                searching = false
                matches = (placemarks ?? []).compactMap { place in
                    guard let coordinate = place.location?.coordinate else { return nil }
                    let name = [place.locality ?? place.name, place.administrativeArea, place.country]
                        .compactMap { $0 }.joined(separator: ", ")
                    return SolarLocation(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                if matches.isEmpty { message = error == nil ? "No city found. Add the country and try again." : "City lookup unavailable. Try again when connected." }
            }
        }
    }
}
