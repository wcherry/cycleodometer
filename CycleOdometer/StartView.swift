import SwiftUI

struct StartView: View {
    var onStart: () -> Void

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
    StartView {}
}
