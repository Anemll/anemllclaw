import SwiftUI

struct AboutSettings: View {
    weak var updater: UpdaterProviding?
    @State private var iconHover = false
    @AppStorage("autoUpdateEnabled") private var autoCheckEnabled = true
    @State private var didLoadUpdaterState = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
            let appIcon = NSApplication.shared.applicationIconImage ?? CritterIconRenderer.makeIcon(blink: 0)
            Button {
                if let url = URL(string: "https://github.com/openclaw/openclaw") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .cornerRadius(24)
                    .shadow(color: self.iconHover ? .accentColor.opacity(0.25) : .clear, radius: 10)
                    .scaleEffect(self.iconHover ? 1.05 : 1.0)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .pointingHandCursor()
            .onHover { hover in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { self.iconHover = hover }
            }

            VStack(spacing: 3) {
                Text("OpenClaw")
                    .font(.title3.bold())
                Text("Version \(self.versionString)")
                    .foregroundStyle(.secondary)
                if let buildTimestamp {
                    Text("Built \(buildTimestamp)\(self.buildSuffix)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Menu bar companion for notifications, screenshots, and privileged agent actions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }

            VStack(alignment: .center, spacing: 6) {
                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: "GitHub",
                    url: "https://github.com/openclaw/openclaw")
                AboutLinkRow(icon: "globe", title: "Website", url: "https://openclaw.ai")
                AboutLinkRow(icon: "bird", title: "Twitter", url: "https://twitter.com/steipete")
                AboutLinkRow(icon: "envelope", title: "Email", url: "mailto:peter@steipete.me")
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 10)

            if let updater {
                Divider()
                    .padding(.vertical, 8)

                if updater.isAvailable {
                    VStack(spacing: 10) {
                        Toggle("Check for updates automatically", isOn: self.$autoCheckEnabled)
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Button("Check for Updates…") { updater.checkForUpdates(nil) }
                    }
                } else {
                    Text("Updates unavailable in this build.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            Divider()
                .padding(.vertical, 8)

            DisclosureGroup("Acknowledgments") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("OpenClaw uses the following open-source libraries.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Self.libraryRow(
                        name: "OpenClawGatewayCore",
                        description: "Local gateway runtime with embedded SQLite memory store, WebSocket/TCP servers, and agentic method router.",
                        license: "Proprietary",
                        author: "OpenClaw contributors")
                    Self.libraryRow(
                        name: "OpenClawKit",
                        description: "Shared UI components, chat transport protocol, and client-side utilities for OpenClaw apps.",
                        license: "Proprietary",
                        author: "OpenClaw contributors")
                    Self.libraryRow(
                        name: "Textual",
                        description: "A Swift package for rendering rich text content including Markdown, LaTeX, and code blocks in SwiftUI.",
                        license: "MIT",
                        author: "Guille Gonzalez",
                        url: "https://github.com/gonzalezreal/textual")
                    Self.libraryRow(
                        name: "SwiftUI Math",
                        description: "Mathematical expression rendering for SwiftUI, used by Textual for LaTeX support.",
                        license: "MIT",
                        author: "Guille Gonzalez, SwiftMath contributors",
                        url: "https://github.com/gonzalezreal/swiftui-math")
                    Self.libraryRow(
                        name: "ElevenLabsKit",
                        description: "Swift SDK for the ElevenLabs text-to-speech and voice synthesis API.",
                        license: "MIT",
                        author: "Peter Steinberger",
                        url: "https://github.com/steipete/ElevenLabsKit")
                    Self.libraryRow(
                        name: "Swift Concurrency Extras",
                        description: "Useful utilities for working with Swift concurrency, including serial executors and async streams.",
                        license: "MIT",
                        author: "Point-Free",
                        url: "https://github.com/pointfreeco/swift-concurrency-extras")
                    Self.libraryRow(
                        name: "SwabbleKit",
                        description: "Lightweight test-double and mock generation toolkit for Swift.",
                        license: "MIT",
                        author: "OpenClaw contributors")
                    Self.libraryRow(
                        name: "Commander",
                        description: "A Swift framework for composing command-line interfaces.",
                        license: "MIT",
                        author: "Peter Steinberger",
                        url: "https://github.com/steipete/Commander")
                    Self.libraryRow(
                        name: "Swift Snapshot Testing",
                        description: "Delightful Swift snapshot testing framework with support for multiple strategies.",
                        license: "MIT",
                        author: "Point-Free",
                        url: "https://github.com/pointfreeco/swift-snapshot-testing")
                    Self.libraryRow(
                        name: "SQLite3",
                        description: "Embedded SQL database engine. Used via system library for the gateway memory store.",
                        license: "Public Domain",
                        author: "D. Richard Hipp and contributors",
                        url: "https://www.sqlite.org")

                    Text("All trademarks are the property of their respective owners.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            Text("© 2025 Peter Steinberger — MIT License.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard let updater, !self.didLoadUpdaterState else { return }
            // Keep Sparkle’s auto-check setting in sync with the persisted toggle.
            updater.automaticallyChecksForUpdates = self.autoCheckEnabled
            updater.automaticallyDownloadsUpdates = self.autoCheckEnabled
            self.didLoadUpdaterState = true
        }
        .onChange(of: self.autoCheckEnabled) { _, newValue in
            self.updater?.automaticallyChecksForUpdates = newValue
            self.updater?.automaticallyDownloadsUpdates = newValue
        }
    }

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var buildTimestamp: String? {
        guard
            let raw =
            (Bundle.main.object(forInfoDictionaryKey: "OpenClawBuildTimestamp") as? String) ??
            (Bundle.main.object(forInfoDictionaryKey: "OpenClawBuildTimestamp") as? String)
        else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return raw }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter.string(from: date)
    }

    private var gitCommit: String {
        (Bundle.main.object(forInfoDictionaryKey: "OpenClawGitCommit") as? String) ??
            (Bundle.main.object(forInfoDictionaryKey: "OpenClawGitCommit") as? String) ??
            "unknown"
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    private var buildSuffix: String {
        let git = self.gitCommit
        guard !git.isEmpty, git != "unknown" else { return "" }

        var suffix = " (\(git)"
        #if DEBUG
        suffix += " DEBUG"
        #endif
        suffix += ")"
        return suffix
    }

    @ViewBuilder
    private static func libraryRow(
        name: String,
        description: String,
        license: String,
        author: String,
        url: String? = nil) -> some View
    {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.callout.weight(.semibold))
            Text(description).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(license, systemImage: "doc.text").font(.caption2).foregroundStyle(.mint)
                Label(author, systemImage: "person").font(.caption2).foregroundStyle(.secondary)
            }
            if let url {
                Button(url) {
                    if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                }
                .buttonStyle(.plain)
                .font(.caption2.monospaced())
                .foregroundStyle(.blue)
                .pointingHandCursor()
            }
        }
    }
}

@MainActor
private struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String

    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: self.icon)
                Text(self.title)
                    .underline(self.hovering, color: .accentColor)
            }
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
        .pointingHandCursor()
    }
}

private struct AboutMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(self.label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(self.value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
        }
    }
}

#if DEBUG
struct AboutSettings_Previews: PreviewProvider {
    private static let updater = DisabledUpdaterController()
    static var previews: some View {
        AboutSettings(updater: updater)
            .frame(width: SettingsTab.windowWidth, height: SettingsTab.windowHeight)
    }
}
#endif
