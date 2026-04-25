import SwiftUI

/// Simple placeholder view for previews to sanity-check the project template.
struct ContentView: View {
    /// Tracks how many times the sample button has been tapped.
    @State private var tapCount = 0

    /// Shows a tiny counter demo so the preview canvas has meaningful content.
    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "ScaffoldWelcomeTitle"))
                .font(.largeTitle)
                .bold()
            Text(String(localized: "ScaffoldReadyBody"))
                .foregroundStyle(.secondary)
            Button(action: { tapCount += 1 }) {
                Label(String(localized: "ScaffoldCounterButton"), systemImage: "plus")
            }
            Text(
                String.localizedStringWithFormat(
                    String(localized: "ScaffoldCounterFormat"),
                    tapCount
                )
            )
                .monospaced()
        }
        .frame(minWidth: 360, minHeight: 240)
        .padding()
    }
}

#Preview {
    ContentView()
}
