import SwiftUI

struct StartView: View {
    var history: RideHistory
    var onStart: () -> Void

    @State private var showingHistory = false

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
            Button {
                showingHistory = true
            } label: {
                Label("Ride History", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(PressScaleStyle())
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(history: history)
        }
    }
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
