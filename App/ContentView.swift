import SwiftUI

/// Simple placeholder view used by previews to sanity-check the project template.
struct ContentView: View {
    /// Tracks how many times the sample button has been tapped.
    @State private var tapCount = 0

    /// Shows a tiny counter demo so the preview canvas has meaningful content.
    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Launchy")
                .font(.largeTitle)
                .bold()
            Text("This SwiftUI scaffold is ready for your ideas.")
                .foregroundStyle(.secondary)
            Button(action: { tapCount += 1 }) {
                Label("Increase Counter", systemImage: "plus")
            }
            Text("Counter: \(tapCount)")
                .monospaced()
        }
        .frame(minWidth: 360, minHeight: 240)
        .padding()
    }
}

#Preview {
    ContentView()
}
