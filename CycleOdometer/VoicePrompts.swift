import AVFoundation
import Foundation

/// Whether turn cues are spoken. On unless turned off in Settings.
enum VoicePromptSetting {
    static let key = "voicePrompts"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Decides what to say, and when, from the ride's guidance: each turn at about 150 m
/// and again at 30 m (the same moments as the haptic taps), leaving and rejoining the
/// route, and finishing or arriving. Pure logic, so it can be tested without speech.
struct Announcer {
    private var lastCue: (kind: Cue.Kind, stage: Int)?
    private var wasOffRoute = false
    private var wasFinished = false

    mutating func announcement(cue: Cue?, isOffRoute: Bool, isFinished: Bool,
                               destinationName: String?, units: UnitSystem) -> String? {
        defer {
            wasOffRoute = isOffRoute
            wasFinished = isFinished
        }
        if isFinished && !wasFinished {
            return destinationName.map { "You have arrived at \(SpokenText.expand($0))." } ?? "Route complete."
        }
        if isOffRoute && !wasOffRoute { return "Off route." }
        if !isOffRoute && wasOffRoute { return "Back on route." }

        guard let cue, cue.stage > 0 else { return nil }
        if let last = lastCue, last.kind == cue.kind, last.stage >= cue.stage { return nil }
        lastCue = (cue.kind, cue.stage)
        let action = SpokenText.action(for: cue)
        return cue.stage == 1
            ? "In \(SpokenText.distance(cue.distance, units: units)), \(SpokenText.lowercasingFirst(action))."
            : "\(action)."
    }
}

/// Cue wording made for listening rather than reading.
enum SpokenText {
    /// "Turn right onto Main Street" for a turn from the route's shape; Apple's own
    /// sentence, with abbreviations spelled out, for its directions.
    static func action(for cue: Cue) -> String {
        guard case .turn = cue.kind else { return expand(cue.instruction) }
        switch cue.instruction {
        case "U-turn": return "Make a U-turn"
        case "Left", "Right": return onto("Turn \(cue.instruction.lowercased())", cue.street)
        default: return onto(cue.instruction, cue.street)
        }
    }

    private static func onto(_ verb: String, _ street: String?) -> String {
        street.map { "\(verb) onto \(expand($0))" } ?? verb
    }

    /// "500 feet", "0.3 miles", "150 meters", "1.2 kilometers".
    static func distance(_ meters: Double, units: UnitSystem) -> String {
        switch units {
        case .imperial:
            let feet = meters * 3.280_84
            if feet < 528 { return "\(max(Int((feet / 50).rounded()) * 50, 50)) feet" }
            let miles = units.distance(meters)
            return miles.formatted(.number.precision(.fractionLength(0...1))) + (abs(miles - 1) < 0.05 ? " mile" : " miles")
        case .metric:
            if meters < 1_000 { return "\(max(Int((meters / 10).rounded()) * 10, 10)) meters" }
            let kilometers = units.distance(meters)
            return kilometers.formatted(.number.precision(.fractionLength(0...1))) + (abs(kilometers - 1) < 0.05 ? " kilometer" : " kilometers")
        }
    }

    /// Spells out the road abbreviations Apple uses, so "Main St" isn't read as
    /// "Main Saint" and "N De Anza Blvd" becomes "North De Anza Boulevard".
    static func expand(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for i in words.indices {
            let core = words[i].trimmingCharacters(in: .punctuationCharacters)
            let trailing = String(words[i].dropFirst(core.count))
            let isFirstOfName = i == 0 || ["onto", "on", "toward", "towards", "at"].contains(words[i - 1].lowercased())
            // A name's first word can be a direction ("N De Anza"), but not a street
            // type: "St James Park" is Saint James.
            if isFirstOfName {
                if let direction = directions[core] { words[i] = direction + trailing }
            } else if let street = streetTypes[core] {
                words[i] = street + trailing
            }
        }
        return words.joined(separator: " ")
    }

    static func lowercasingFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    private static let streetTypes = [
        "St": "Street", "Ave": "Avenue", "Blvd": "Boulevard", "Dr": "Drive", "Rd": "Road",
        "Ln": "Lane", "Ct": "Court", "Pl": "Place", "Pkwy": "Parkway", "Hwy": "Highway",
        "Expy": "Expressway", "Cir": "Circle", "Ter": "Terrace", "Trl": "Trail", "Wy": "Way",
    ]
    private static let directions = [
        "N": "North", "S": "South", "E": "East", "W": "West",
        "NE": "Northeast", "NW": "Northwest", "SE": "Southeast", "SW": "Southwest",
    ]
}

/// Speaks announcements, lowering other audio (music, podcasts) while it talks and
/// restoring it afterwards. Keeps working with the screen locked, via the "audio"
/// background mode.
final class VoicePrompter: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        do {
            // .voicePrompt is the mode made for navigation prompts; ducking lowers
            // other apps' audio, and spoken audio (podcasts) pauses rather than talks over.
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        // A newer prompt replaces one still being spoken: it's the one that matters now.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        release()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        release()
    }

    /// Gives other apps their full volume back once nothing is left to say.
    private func release() {
        guard !synthesizer.isSpeaking else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
