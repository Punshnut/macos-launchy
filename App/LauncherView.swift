import SwiftUI
import AppKit

struct LauncherView: View {
    let apps: [AppItem]
    var onLaunch: (AppItem) -> Void = { _ in }

    private let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .top)
    ]
    private let pageSize = 30

    @State private var currentPage = 0

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(currentPageApps) { app in
                            Button {
                                onLaunch(app)
                            } label: {
                                VStack(spacing: 8) {
                                    iconView(for: app)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 64, height: 64)
                                    Text(app.name)
                                        .font(.caption)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(nsColor: .windowBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color(nsColor: .separatorColor))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(20)
                }

                HStack(spacing: 16) {
                    Button("Previous") {
                        currentPage = max(currentPage - 1, 0)
                    }
                    .disabled(currentPage == 0 || apps.isEmpty)

                    Text(pageIndicatorText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Next") {
                        currentPage = min(currentPage + 1, totalPages - 1)
                    }
                    .disabled(apps.isEmpty || currentPage >= totalPages - 1)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .onChange(of: apps) { _ in
            currentPage = 0
        }
    }

    private var totalPages: Int {
        let count = apps.count
        guard count > 0 else { return 1 }
        return (count + pageSize - 1) / pageSize
    }

    private var currentPageApps: [AppItem] {
        guard apps.isEmpty == false else { return [] }
        let start = currentPage * pageSize
        let end = min(start + pageSize, apps.count)
        if start >= apps.count { return [] }
        return Array(apps[start..<end])
    }

    private var pageIndicatorText: String {
        guard apps.isEmpty == false else { return "No apps found" }
        return "Page \(currentPage + 1) of \(totalPages)"
    }

    private func iconView(for app: AppItem) -> Image {
        if let nsImage = app.icon {
            return Image(nsImage: nsImage)
        } else {
            return Image(systemName: "app.fill")
        }
    }
}

#Preview {
    LauncherView(
        apps: [
            AppItem(id: UUID(), name: "Safari", bundleIdentifier: "com.apple.Safari", icon: NSImage(named: NSImage.networkName), url: nil),
            AppItem(id: UUID(), name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", icon: nil, url: nil),
            AppItem(id: UUID(), name: "Notes", bundleIdentifier: "com.apple.Notes", icon: nil, url: nil)
        ],
        onLaunch: { _ in }
    )
}
