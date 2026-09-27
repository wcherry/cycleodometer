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
    /// Whether a GPS track was saved for this ride. Rides recorded before tracks
    /// existed don't have one.
    var hasTrack = false

    /// Distance over moving time, in metres per second.
    var averageSpeed: Double {
        duration > 0 ? distance / duration : 0
    }

    init(id: UUID = UUID(), date: Date, duration: TimeInterval, distance: Double, topSpeed: Double, hasTrack: Bool = false) {
        self.id = id
        self.date = date
        self.duration = duration
        self.distance = distance
        self.topSpeed = topSpeed
        self.hasTrack = hasTrack
    }

    // Written by hand only so `hasTrack` can be missing from older rides.json files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        distance = try container.decode(Double.self, forKey: .distance)
        topSpeed = try container.decode(Double.self, forKey: .topSpeed)
        hasTrack = try container.decodeIfPresent(Bool.self, forKey: .hasTrack) ?? false
    }
}

/// The most recent rides, newest first, kept in a JSON file in Application Support.
/// Each ride's track is a GPX file beside it, in `tracks/<ride id>.gpx`.
@Observable
final class RideHistory {
    static let limit = 20

    private(set) var rides: [RideRecord] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let tracksDirectory: URL

    init(fileURL: URL = RideHistory.defaultFileURL) {
        self.fileURL = fileURL
        tracksDirectory = fileURL.deletingLastPathComponent().appending(path: "tracks", directoryHint: .isDirectory)
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([RideRecord].self, from: data) {
            rides = saved
        }
        removeOrphanedTracks()
    }

    /// Records a ride and its track, unless it was a false start: under a minute with
    /// no distance.
    func add(_ ride: RideRecord, track: Track = Track()) {
        guard ride.duration >= 60 || ride.distance > 0 else { return }
        var ride = ride
        ride.hasTrack = !track.isEmpty && saveTrack(track, for: ride)
        rides.insert(ride, at: 0)
        for dropped in rides.dropFirst(Self.limit) {
            deleteTrack(for: dropped)
        }
        rides = Array(rides.prefix(Self.limit))
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            deleteTrack(for: rides[index])
        }
        rides.remove(atOffsets: offsets)
        save()
    }

    /// Reads a ride's track off the main thread; nil if it has none or it can't be read.
    func loadTrack(for ride: RideRecord) async -> Track? {
        guard ride.hasTrack else { return nil }
        let url = trackURL(for: ride)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? GPX.parse(data).track
        }.value
    }

    func trackURL(for ride: RideRecord) -> URL {
        tracksDirectory.appending(path: "\(ride.id.uuidString).gpx")
    }

    private func saveTrack(_ track: Track, for ride: RideRecord) -> Bool {
        do {
            try FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
            try Data(GPX.document(for: track).utf8).write(to: trackURL(for: ride), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func deleteTrack(for ride: RideRecord) {
        try? FileManager.default.removeItem(at: trackURL(for: ride))
    }

    /// Clears track files no ride refers to, e.g. left behind if the app was killed
    /// between writing a track and saving the history.
    private func removeOrphanedTracks() {
        let kept = Set(rides.filter(\.hasTrack).map { trackURL(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
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
