import SwiftUI

struct StartView: View {
    var history: RideHistory
    var onStart: () -> Void

    @State private var showingHistory = false
    @State private var pickingRoute = false
    @State private var navigating = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Button(action: onStart) {
                VStack(spacing: 12) {
                    Image(systemName: "bicycle")
                        .font(.system(size: 64, weight: .semibold))
                    Text("START RIDE")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(.black)
                .frame(width: 260, height: 260)
                .background(Circle().fill(Color.green))
                .shadow(color: .green.opacity(0.5), radius: 30)
            }
            .buttonStyle(PressScaleStyle())
        }
        .overlay(alignment: .topTrailing) {
            SettingsButton()
                .padding(.trailing, 24)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                bottomButton("Ride a Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    pickingRoute = true
                }
                bottomButton("Navigate To…", systemImage: "arrow.triangle.turn.up.right.diamond") {
                    navigating = true
                }
                bottomButton("Ride History", systemImage: "clock.arrow.circlepath") {
                    showingHistory = true
                }
            }
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(history: history)
        }
        .sheet(isPresented: $navigating) {
            NavigateView()
        }
        .sheet(isPresented: $pickingRoute) {
            NavigationStack {
                RoutesView(picking: true)
            }
        }
    }
}

private func bottomButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(minWidth: 200)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }
    .buttonStyle(PressScaleStyle())
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    StartView(history: RideHistory()) {}
}
