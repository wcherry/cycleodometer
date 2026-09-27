import Foundation

/// Reads and writes GPX 1.1, the format tracks are stored in and shared as.
///
/// Speed goes in Garmin's TrackPointExtension, which Strava, Komoot and most
/// other tools understand; GPX itself has no speed field.
enum GPX {
    enum ParseError: Error, Equatable {
        case invalidXML
        case noTrack
    }

    static func document(for track: Track, name: String? = nil) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Cycle Odometer" \
        xmlns="http://www.topografix.com/GPX/1/1" \
        xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
          <trk>

        """
        if let name {
            xml += "    <name>\(escape(name))</name>\n"
        }
        for segment in track.drawableSegments {
            xml += "    <trkseg>\n"
            for point in segment {
                xml += "      <trkpt lat=\"\(coordinate(point.latitude))\" lon=\"\(coordinate(point.longitude))\">"
                if let elevation = point.elevation {
                    xml += "<ele>\(String(format: "%.1f", elevation))</ele>"
                }
                if let time = point.time {
                    xml += "<time>\(timeFormatter.string(from: time))</time>"
                }
                if let speed = point.speed {
                    xml += "<extensions><gpxtpx:TrackPointExtension>"
                        + "<gpxtpx:speed>\(String(format: "%.2f", speed))</gpxtpx:speed>"
                        + "</gpxtpx:TrackPointExtension></extensions>"
                }
                xml += "</trkpt>\n"
            }
            xml += "    </trkseg>\n"
        }
        xml += "  </trk>\n</gpx>\n"
        return xml
    }

    /// Parses tracks (`<trk>/<trkseg>/<trkpt>`) and routes (`<rte>/<rtept>`); each
    /// track segment or route becomes one segment. Waypoints (`<wpt>`) are ignored.
    static func parse(_ data: Data) throws -> (name: String?, track: Track) {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.invalidXML }
        let track = Track(segments: delegate.segments)
        guard !track.isEmpty else { throw ParseError.noTrack }
        return (delegate.name, track)
    }

    private static func coordinate(_ degrees: Double) -> String {
        String(format: "%.7f", degrees)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    fileprivate static func parseTime(_ text: String) -> Date? {
        if let date = timeFormatter.date(from: text) { return date }
        // Most other apps write whole seconds.
        return ISO8601DateFormatter().date(from: text)
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    var name: String?
    var segments: [[TrackPoint]] = []

    private var elements: [String] = []
    private var point: TrackPoint?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        elements.append(element)
        text = ""
        switch element {
        case "trkseg", "rte":
            segments.append([])
        case "trkpt", "rtept":
            guard let lat = attributes["lat"].flatMap(Double.init),
                  let lon = attributes["lon"].flatMap(Double.init) else { return }
            point = TrackPoint(latitude: lat, longitude: lon)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        elements.removeLast()
        let parent = elements.last

        switch element {
        case "ele":
            point?.elevation = Double(value)
        case "time":
            point?.time = GPX.parseTime(value)
        case "speed":
            point?.speed = Double(value)
        case "name" where name == nil && ["trk", "rte", "metadata"].contains(parent ?? ""):
            name = value.isEmpty ? nil : value
        case "trkpt", "rtept":
            if let point, !segments.isEmpty {
                segments[segments.count - 1].append(point)
            }
            point = nil
        default:
            break
        }
        text = ""
    }
}
