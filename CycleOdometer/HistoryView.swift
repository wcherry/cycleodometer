import SwiftUI

struct HistoryView: View {
    var history: RideHistory

    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if history.rides.isEmpty {
                    ContentUnavailableView(
                        "No Rides Yet",
                        systemImage: "bicycle",
                        description: Text("Your last \(RideHistory.limit) rides will appear here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(history.rides) { ride in
                                RideRow(ride: ride, units: units)
                            }
                            .onDelete(perform: history.delete)
                        } footer: {
                            Text(units == .imperial
                                 ? "Distance in miles, speed in mph."
                                 : "Distance in kilometers, speed in km/h.")
                        }
                    }
                }
            }
            .navigationTitle("Ride History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RideRow: View {
    var ride: RideRecord
    var units: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ride.date, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                .font(.headline)

            // Fixed proportions, so the columns line up from one ride to the next. Units
            // are in the list's footer, leaving the values room at large text sizes.
            ProportionalStack(weights: [1.3, 1.3, 1, 1]) {
                Stat(title: "TIME", value: Self.duration(ride.duration))
                Stat(title: "DISTANCE", value: format(units.distance(ride.distance), digits: 2))
                Stat(title: "TOP", value: format(units.speed(ride.topSpeed), digits: 1))
                Stat(title: "AVG", value: format(units.speed(ride.averageSpeed), digits: 1))
            }
            // Four columns can't grow without limit: past this, each label would shrink
            // by a different amount to fit and the row would look uneven.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func format(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// `H:MM:SS`, or `MM:SS` under an hour.
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct Stat: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                // Shrink rather than wrap: a wrapped title pushes its value out of line.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays its children out side by side, each taking a fixed share of the width in
/// proportion to `weights`, whatever its content.
private struct ProportionalStack: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 8

    private func widths(for total: CGFloat, count: Int) -> [CGFloat] {
        let weights = (0..<count).map { $0 < self.weights.count ? self.weights[$0] : 1 }
        let available = max(total - spacing * CGFloat(count - 1), 0)
        let sum = weights.reduce(0, +)
        return weights.map { available * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let columns = widths(for: width, count: subviews.count)
        let height = zip(subviews, columns)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
