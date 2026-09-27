import Foundation
import Observation
import SwiftUI

/// One finished ride. Stored in SI units, like `RideTracker`.
struct RideRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    /// Time on the stopwatch, excluding pauses, in seconds.
    var duration: TimeInterval
    /// In metres.
    var distance: Double
    /// In metres per second.
    var topSpeed: Double

    /// Distance over moving time, in metres per second.
    var averageSpeed: Double {
        duration > 0 ? distance / duration : 0
    }
}

/// The most recent rides, newest first, kept in a JSON file in Application Support.
@Observable
final class RideHistory {
    static let limit = 20

    private(set) var rides: [RideRecord] = []

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = RideHistory.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([RideRecord].self, from: data) {
            rides = saved
        }
    }

    /// Records a ride unless it was a false start: under a minute with no distance.
    func add(_ ride: RideRecord) {
        guard ride.duration >= 60 || ride.distance > 0 else { return }
        rides.insert(ride, at: 0)
        rides = Array(rides.prefix(Self.limit))
        save()
    }

    func delete(at offsets: IndexSet) {
        rides.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(rides).write(to: fileURL, options: .atomic)
        } catch {
            // Losing the history is a nuisance, not worth interrupting a ride over.
        }
    }

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "rides.json")
    }
}
