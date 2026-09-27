import SwiftUI

struct RideView: View {
    var ride: RideTracker

    @Environment(RideHistory.self) private var history

    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    @AppStorage(RiderType.storageKey) private var rider = RiderType.competitive
    @State private var flashlight = Flashlight()
    /// When the warning flasher was switched on, or nil when it's off.
    @State private var warningSince: Date?
    @State private var showingMap = false
    /// Set briefly after rejoining the route, to show "Back on route".
    @State private var recentlyRejoined = false

    private let buttonSpacing: CGFloat = 16

    var body: some View {
        Group {
            if showingMap {
                RideMapView(ride: ride, routeStatus: routeStatus) { showingMap = false }
            } else {
                gauge
            }
        }
        // On both screens: the alerts matter most when you aren't looking.
        .sensoryFeedback(.warning, trigger: isOffRoute) { _, offRoute in offRoute }
        .sensoryFeedback(.success, trigger: isOffRoute) { wasOff, offRoute in wasOff && !offRoute }
        .sensoryFeedback(.success, trigger: ride.follower?.isFinished ?? false) { _, finished in finished }
        // A light tap about 150 m before each turn and again at 30 m.
        .sensoryFeedback(.impact(weight: .light), trigger: cueStage) { old, new in
            new.stage > 0 && (new.kind != old.kind || new.stage > old.stage)
        }
        .onChange(of: isOffRoute) { wasOff, offRoute in
            if wasOff && !offRoute { recentlyRejoined = true }
        }
        .task(id: recentlyRejoined) {
            guard recentlyRejoined else { return }
            try? await Task.sleep(for: .seconds(4))
            recentlyRejoined = false
        }
    }

    private var isOffRoute: Bool { ride.follower?.isOffRoute ?? false }

    private var routeStatus: RouteStatus? {
        ride.follower.map { RouteStatus(follower: $0, recentlyRejoined: recentlyRejoined, cue: ride.currentCue) }
    }

    private struct CueStage: Equatable {
        var kind: Cue.Kind?
        var stage: Int
    }

    private var cueStage: CueStage {
        let cue = ride.currentCue
        return CueStage(kind: cue?.kind, stage: cue?.stage ?? 0)
    }

    private var gauge: some View {
        VStack(spacing: 20) {
            // 95% of the screen width, reaching past the page padding; the ring, its labels
            // and the top-speed bug all sit inside the gauge's own frame.
            SpeedGauge(
                speed: units.speed(ride.speed),
                topSpeed: units.speed(ride.maxSpeed),
                maxValue: rider.gaugeMax(in: units),
                tickStep: rider.tickStep(in: units),
                unitLabel: units.speedLabel,
                unitName: units.speedName,
                grade: ride.grade,
                showsGrade: ride.canMeasureGrade
            )
                .containerRelativeFrame(.horizontal) { width, _ in width * 0.95 }
                .padding(.top, 12)

            HStack(spacing: 16) {
                StatTile(title: "DISTANCE") {
                    let value = Text(units.distance(ride.distance), format: .number.precision(.fractionLength(2)))
                    let unit = Text(units.distanceLabel).font(.title3).foregroundStyle(.secondary)
                    Text("\(value) \(unit)")
                }
                StatTile(title: "TIME") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Text(Self.format(ride.elapsed(at: context.date)))
                    }
                }
            }

            if let follower = ride.follower, let status = routeStatus {
                RouteStatusCard(status: status, follower: follower, routeName: ride.routeName,
                                navigation: ride.navigation, heading: ride.heading)
            }

            Spacer(minLength: 0)

            GeometryReader { proxy in
                let third = (proxy.size.width - buttonSpacing) / 3
                ZStack(alignment: .trailing) {
                    HStack(spacing: buttonSpacing) {
                        ControlButton(
                            title: ride.isRunning ? "Pause Ride" : "Resume Ride",
                            systemImage: ride.isRunning ? "pause.fill" : "play.fill",
                            tint: ride.isRunning ? .orange : .green
                        ) { ride.toggleTimer() }
                        .frame(width: third * 2)

                        // Paused, the slider's handle takes this slot, drawn over the row below.
                        lightButton
                            .frame(width: third)
                            .opacity(ride.isRunning ? 1 : 0)
                            .allowsHitTesting(ride.isRunning)
                    }

                    if !ride.isRunning {
                        SlideToEnd(handleWidth: third, onComplete: endRide)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: ride.isRunning)
            }
            .frame(height: ControlButton.height)
        }
        .padding()
        // Settings live on the start screen; mid-ride, only the map is up here.
        .overlay(alignment: .topTrailing) {
            Button {
                showingMap = true
            } label: {
                Image(systemName: "map.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Map")
            .padding(.trailing, 8)
        }
        .overlay(alignment: .topLeading) {
            CompassView(heading: ride.heading)
                .padding(.leading, 12)
        }
        .background { WarningBackground(since: warningSince).ignoresSafeArea() }
    }

    private func endRide() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if flashlight.isOn { flashlight.toggle() }
        warningSince = nil
        let finished = ride.end()
        history.add(finished.record, track: finished.track)
    }

    /// Tap toggles the flashlight; a long press toggles the red warning flasher.
    /// While the flasher is on, a tap switches it off too, so it's never hard to stop.
    private var lightButton: some View {
        let warning = warningSince != nil
        return ControlButton(
            title: warning ? "Warning" : (flashlight.isOn ? "Light Off" : "Light"),
            systemImage: warning
                ? "exclamationmark.triangle.fill"
                : (flashlight.isOn ? "flashlight.on.fill" : "flashlight.off.fill"),
            tint: warning ? .red : (flashlight.isOn ? .yellow : .gray),
            action: {
                if warning {
                    warningSince = nil
                } else if flashlight.isAvailable {
                    flashlight.toggle()
                }
            },
            longPressAction: {
                warningSince = warning ? nil : .now
            },
            longPressName: warning ? "Stop warning flasher" : "Start warning flasher"
        )
        .sensoryFeedback(.impact(weight: .heavy), trigger: warning)
    }

    /// `H:MM:SS.t`, or `MM:SS.t` under an hour.
    static func format(_ interval: TimeInterval) -> String {
        let tenths = Int(interval * 10)
        let h = tenths / 36_000
        let m = tenths / 600 % 60
        let s = tenths / 10 % 60
        let t = tenths % 10
        return h > 0
            ? String(format: "%d:%02d:%02d.%d", h, m, s, t)
            : String(format: "%02d:%02d.%d", m, s, t)
    }
}

private struct StatTile<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(TilePlate(cornerRadius: 16, tint: Color.white.opacity(0.08)))
    }
}

/// Ends the ride only once its handle has been dragged from the right-hand slot all
/// the way to the left edge of the row — too deliberate to happen by a stray tap or a
/// bump in the road. Let go short of the edge and the handle springs back.
private struct SlideToEnd: View {
    var handleWidth: CGFloat
    var onComplete: () -> Void

    /// How far the handle has been dragged left: 0 at rest, `-travel` at the end.
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - handleWidth, 1)
            let progress = -offset / travel

            ZStack(alignment: .trailing) {
                // Once a drag starts, the track covers the whole row (Resume included) and
                // points the way; the part behind the handle fills in as it goes.
                TilePlate(cornerRadius: 20, tint: Color.red.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Label("Slide to end", systemImage: "chevron.left.2")
                            .font(.headline)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .padding(.leading, 20)
                            .opacity(max(0, 1 - progress * 1.6))
                    }
                    .opacity(offset < 0 ? 1 : 0)

                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.red.opacity(0.45))
                    .frame(width: handleWidth - offset)

                VStack(spacing: 8) {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 34, weight: .semibold))
                    Text("End Ride")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
                .frame(width: handleWidth)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color.red))
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            offset = min(0, max(-travel, value.translation.width))
                        }
                        .onEnded { _ in
                            // "All the way": the handle has to reach the left edge.
                            if offset <= -travel + 2 {
                                onComplete()
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = 0 }
                            }
                        }
                )
            }
            .frame(width: proxy.size.width, alignment: .trailing)
            .sensoryFeedback(.impact(weight: .medium), trigger: progress >= 0.99)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("End ride")
        .accessibilityHint("Drag left to the edge to end the ride")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onComplete() }
    }
}

/// Flashes the whole screen red and black, twice a second, like a warning light.
private struct WarningBackground: View {
    var since: Date?

    private static let interval = 0.5

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: Self.interval)) { context in
                let phase = Int(context.date.timeIntervalSince(since) / Self.interval)
                (phase.isMultiple(of: 2) ? Color.red : Color.black)
            }
        } else {
            Color.black
        }
    }
}

private struct ControlButton: View {
    static let height: CGFloat = 110

    var title: String
    var systemImage: String
    var tint: Color
    var action: () -> Void
    var longPressAction: (() -> Void)?
    /// VoiceOver name for the long-press action, which has no gesture there.
    var longPressName: String = ""

    @State private var isPressed = false

    var body: some View {
        if let longPressAction {
            // Not a Button: a Button fires its action on release even after a long press.
            label
                .scaleEffect(isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.15), value: isPressed)
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .onLongPressGesture(minimumDuration: 0.6, perform: longPressAction) { isPressed = $0 }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: longPressName, longPressAction)
        } else {
            Button(action: action) { label }
                .buttonStyle(PressScaleStyle())
        }
    }

    private var label: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(tint)
        .background(TilePlate(cornerRadius: 20, tint: tint.opacity(0.18)))
    }
}

/// A tinted rounded rectangle on an opaque black base, so tiles and buttons stay
/// readable while the warning flasher turns the screen behind them red.
struct TilePlate: View {
    var cornerRadius: CGFloat
    var tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            shape.fill(Color.black)
            shape.fill(tint)
        }
    }
}
