import SwiftUI

/// What this is and the licence the avatar ships under. bloub is MIT and its terms require the
/// notice to travel with every copy, so it lives in the app rather than only in `apple/README.md`.
/// Which daemon this is talking to is the Daemon page's, next door in Settings.
struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    // Its own look rather than the store's: the About sheet the Mac's app menu
                    // opens is outside the view that carries one.
                    BloubView(state: .idle, identity: .standard(for: "schermes"), size: 92)
                    Text("schermes").font(.title2.weight(.semibold))
                    Text("Version \(version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Text(bloubCredit)
                    .font(.footnote)
                Text(verbatim: bloubLicence)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("The avatar")
            } footer: {
                Text("Everything else here is URLSession, SwiftUI and Swift Testing: no packages.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsCategory.about.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The same page as a sheet, for the Mac's own About item in the app menu. That lives outside
/// every window, so it carries no session and needs none.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AboutPage()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}

private let bloubCredit = """
Each agent is a bloub: a Swift port of bloub by Jérémy Perret \
(github.com/jeremy-prt/bloub), at commit b4bb3c1b5f93c7b87a2e8d620f667c4093d97749.
"""

private let bloubLicence = """
MIT License

Copyright (c) 2026 Jérémy Perret

Permission is hereby granted, free of charge, to any person obtaining a copy \
of this software and associated documentation files (the "Software"), to deal \
in the Software without restriction, including without limitation the rights \
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is \
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all \
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
SOFTWARE.
"""
