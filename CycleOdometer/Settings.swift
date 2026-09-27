import SwiftUI

enum UnitSystem: String, CaseIterable, Identifiable {
    case imperial, metric

    static let storageKey = "unitSystem"

    var id: Self { self }

    var title: String {
        switch self {
        case .imperial: "Miles"
        case .metric: "Kilometers"
        }
    }

    var speedLabel: String {
        switch self {
        case .imperial: "MPH"
        case .metric: "KM/H"
        }
    }

    var speedName: String {
        switch self {
        case .imperial: "miles per hour"
        case .metric: "kilometers per hour"
        }
    }

    var distanceLabel: String {
        switch self {
        case .imperial: "mi"
        case .metric: "km"
        }
    }

    /// Converts metres per second to this system's speed unit.
    func speed(_ metersPerSecond: Double) -> Double {
        switch self {
        case .imperial: metersPerSecond * 2.236_936
        case .metric: metersPerSecond * 3.6
        }
    }

    /// Converts metres to this system's distance unit.
    func distance(_ meters: Double) -> Double {
        switch self {
        case .imperial: meters / 1_609.344
        case .metric: meters / 1_000
        }
    }
}

enum RiderType: String, CaseIterable, Identifiable {
    case casual, competitive

    static let storageKey = "riderType"

    var id: Self { self }

    var title: String {
        switch self {
        case .casual: "Casual"
        case .competitive: "Competitive"
        }
    }

    /// Top of the speed gauge. The metric scales are round numbers close to the
    /// imperial ones (25 km/h ≈ 15.5 mph, 50 km/h ≈ 31 mph).
    func gaugeMax(in units: UnitSystem) -> Double {
        switch (self, units) {
        case (.casual, .imperial): 15
        case (.competitive, .imperial): 30
        case (.casual, .metric): 25
        case (.competitive, .metric): 50
        }
    }

    /// Spacing of the gauge's numbered ticks, giving six or seven labels on every scale.
    func tickStep(in units: UnitSystem) -> Int {
        switch (self, units) {
        case (.casual, .imperial): 3
        case (.competitive, .imperial): 5
        case (.casual, .metric): 5
        case (.competitive, .metric): 10
        }
    }
}

struct SettingsView: View {
    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    @AppStorage(RiderType.storageKey) private var rider = RiderType.competitive
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $units) {
                        ForEach(UnitSystem.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Units")
                } footer: {
                    Text("Speed in \(units.speedName), distance in \(units == .imperial ? "miles" : "kilometers").")
                }

                Section {
                    Picker("Rider", selection: $rider) {
                        ForEach(RiderType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Rider")
                } footer: {
                    Text("The speed gauge runs from 0 to \(Int(rider.gaugeMax(in: units))) \(units.speedLabel.lowercased()).")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The gear in the top-right corner of both screens.
struct SettingsButton: View {
    @State private var showingSettings = false

    var body: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

#Preview {
    SettingsView()
        .preferredColorScheme(.dark)
}
