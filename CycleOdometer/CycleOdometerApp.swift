import SwiftUI

@main
struct CycleOdometerApp: App {
    @State private var ride = RideTracker()
    @State private var history = RideHistory()
    @State private var routes = RouteLibrary()
    /// The result of opening a GPX file from another app.
    @State private var importMessage: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if ride.isActive {
                    RideView(ride: ride)
                } else {
                    StartView(history: history) { ride.start() }
                }
            }
            .environment(ride)
            .environment(history)
            .environment(routes)
            // A .gpx file opened in Cycle from Files, Mail, AirDrop or another app.
            .onOpenURL { url in
                do {
                    let route = try routes.importGPX(from: url)
                    importMessage = "“\(route.name)” was added to your routes."
                } catch {
                    importMessage = error.localizedDescription
                }
                // iOS hands other apps' files over as copies in Documents/Inbox.
                if url.path().contains("/Documents/Inbox/") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            .alert("Import GPX", isPresented: Binding(
                get: { importMessage != nil }, set: { if !$0 { importMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
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
