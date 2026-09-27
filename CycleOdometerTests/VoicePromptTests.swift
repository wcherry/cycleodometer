import Foundation
import Testing
@testable import CycleOdometer

@Suite struct SpokenTextTests {
    @Test func expandsRoadAbbreviations() {
        #expect(SpokenText.expand("Turn right onto N De Anza Blvd") == "Turn right onto North De Anza Boulevard")
        #expect(SpokenText.expand("Continue onto E Homestead Rd.") == "Continue onto East Homestead Road.")
        #expect(SpokenText.expand("Main St") == "Main Street")
        // St at the start of a name is Saint, and is left for the voice to read.
        #expect(SpokenText.expand("St James St") == "St James Street")
    }

    @Test func distances() {
        #expect(SpokenText.distance(150, units: .imperial) == "500 feet")
        #expect(SpokenText.distance(30, units: .imperial) == "100 feet")
        #expect(SpokenText.distance(1_609.344, units: .imperial) == "1 mile")
        #expect(SpokenText.distance(3_000, units: .imperial) == "1.9 miles")
        #expect(SpokenText.distance(150, units: .metric) == "150 meters")
        #expect(SpokenText.distance(1_200, units: .metric) == "1.2 kilometers")
    }

    @Test func turnActions() {
        #expect(SpokenText.action(for: Cue(kind: .turn(0), symbol: "", instruction: "Right", street: "Main St", distance: 0))
                == "Turn right onto Main Street")
        #expect(SpokenText.action(for: Cue(kind: .turn(0), symbol: "", instruction: "Bear left", distance: 0))
                == "Bear left")
        #expect(SpokenText.action(for: Cue(kind: .turn(0), symbol: "", instruction: "U-turn", street: "Main St", distance: 0))
                == "Make a U-turn")
        #expect(SpokenText.action(for: Cue(kind: .step(2), symbol: "", instruction: "Turn left onto Stevens Creek Blvd", distance: 0))
                == "Turn left onto Stevens Creek Boulevard")
    }
}

@Suite struct AnnouncerTests {
    private func turn(_ index: Int, at distance: Double) -> Cue {
        Cue(kind: .turn(index), symbol: "", instruction: "Right", street: "Main St", distance: distance)
    }

    @Test func eachTurnIsSpokenAtOneFiftyAndThirtyMetres() {
        var announcer = Announcer()
        func say(_ cue: Cue?) -> String? {
            announcer.announcement(cue: cue, isOffRoute: false, isFinished: false, destinationName: nil, units: .imperial)
        }
        #expect(say(turn(0, at: 400)) == nil)
        #expect(say(turn(0, at: 150)) == "In 500 feet, turn right onto Main Street.")
        #expect(say(turn(0, at: 100)) == nil)
        #expect(say(turn(0, at: 30)) == "Turn right onto Main Street.")
        #expect(say(turn(0, at: 10)) == nil)
        // The next turn, already close: spoken straight away.
        #expect(say(turn(1, at: 120)) == "In 400 feet, turn right onto Main Street.")
    }

    @Test func routeNews() {
        var announcer = Announcer()
        #expect(announcer.announcement(cue: nil, isOffRoute: true, isFinished: false, destinationName: nil, units: .metric) == "Off route.")
        #expect(announcer.announcement(cue: nil, isOffRoute: true, isFinished: false, destinationName: nil, units: .metric) == nil)
        #expect(announcer.announcement(cue: nil, isOffRoute: false, isFinished: false, destinationName: nil, units: .metric) == "Back on route.")
        #expect(announcer.announcement(cue: nil, isOffRoute: false, isFinished: true, destinationName: nil, units: .metric) == "Route complete.")

        var navigating = Announcer()
        #expect(navigating.announcement(cue: nil, isOffRoute: false, isFinished: true, destinationName: "Philz Coffee on Stevens Creek Blvd",
                                        units: .metric) == "You have arrived at Philz Coffee on Stevens Creek Boulevard.")
    }
}
