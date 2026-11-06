import AppKit
import SwiftUI

@MainActor
enum BundledImageLoader {
    private static var imageCache: [String: NSImage] = [:]

    static func load(_ name: String) -> NSImage? {
        if let cached = imageCache[name] {
            return cached
        }

        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            imageCache[name] = img
            return img
        }

        let bundleRes = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/\(name).png")
        if FileManager.default.fileExists(atPath: bundleRes.path),
           let img = NSImage(contentsOf: bundleRes) {
            imageCache[name] = img
            return img
        }

        // 开发态直接运行可执行文件时的本地回退路径（含当前目录与可执行文件上溯路径）
        var candidateRoots: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]
        for start in [Bundle.main.bundleURL, Bundle.main.executableURL].compactMap({ $0 }) {
            var cursor = start
            for _ in 0..<6 {
                cursor = cursor.deletingLastPathComponent()
                candidateRoots.append(cursor)
            }
        }
        for root in candidateRoots {
            let resURL = root.appendingPathComponent("Apps/VCSExplorer/Resources/\(name).png")
            if FileManager.default.fileExists(atPath: resURL.path),
               let img = NSImage(contentsOf: resURL) {
                imageCache[name] = img
                return img
            }
        }
        return nil
    }
}

struct EmptyStateView<Actions: View>: View {
    let imageName: String?
    let fallbackSymbol: String
    let title: String
    let subtitle: String
    var maxImageWidth: CGFloat = 200
    var maxImageHeight: CGFloat = 140
    @ViewBuilder let actions: () -> Actions

    init(
        imageName: String? = nil,
        fallbackSymbol: String = "doc.text.magnifyingglass",
        title: String,
        subtitle: String,
        maxImageWidth: CGFloat = 200,
        maxImageHeight: CGFloat = 140,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.imageName = imageName
        self.fallbackSymbol = fallbackSymbol
        self.title = title
        self.subtitle = subtitle
        self.maxImageWidth = maxImageWidth
        self.maxImageHeight = maxImageHeight
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 16) {
            if let name = imageName, let nsImage = BundledImageLoader.load(name) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: maxImageWidth, maxHeight: maxImageHeight)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.brandGradient.opacity(0.14))
                        .frame(width: 84, height: 84)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Theme.brandGradient.opacity(0.35), lineWidth: 1)
                        )
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.brandGradient)
                }
            }

            VStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }

            actions()
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
