import SwiftUI

struct ContentView: View {
    @State private var counter = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Launchy")
                .font(.largeTitle)
                .bold()
            Text("This SwiftUI scaffold is ready for your ideas.")
                .foregroundStyle(.secondary)
            Button(action: { counter += 1 }) {
                Label("Increase Counter", systemImage: "plus")
            }
            Text("Counter: \(counter)")
                .monospaced()
        }
        .frame(minWidth: 360, minHeight: 240)
        .padding()
    }
}

#Preview {
    ContentView()
}
