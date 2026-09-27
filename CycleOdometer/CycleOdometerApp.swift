import SwiftUI

@main
struct CycleOdometerApp: App {
    @State private var ride = RideTracker()
    @State private var history = RideHistory()

    var body: some Scene {
        WindowGroup {
            Group {
                if ride.isActive {
                    RideView(ride: ride)
                } else {
                    StartView(history: history) { ride.start() }
                }
            }
            .environment(history)
            .preferredColorScheme(.dark)
            .animation(.easeInOut, value: ride.isActive)
            #if DEBUG
            // `-startRide` skips the start screen, for simulator screenshots.
            .onAppear {
                if CommandLine.arguments.contains("-startRide"), !ride.isActive { ride.start() }
            }
            #endif
        }
    }
}
