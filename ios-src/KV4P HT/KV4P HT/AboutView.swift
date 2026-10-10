import SwiftUI

// MARK: - About
// Version info, source/license (GPLv3 §6: binary distribution must carry the
// license and point to the Corresponding Source), and the amateur-license
// notice. LICENSE-GPLv3.txt is a copy of LICENSE at the repo root.

struct AboutView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    static let sourceURL = URL(string: "https://github.com/PilotJ357/kv4p-ht")!
    static let upstreamURL = URL(string: "https://github.com/VanceVagell/kv4p-ht")!
    static let privacyURL = URL(string: "https://github.com/PilotJ357/kv4p-ht/blob/main/ios-privacy-policy.md")!

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    private var firmwareVersion: String {
        store.ble.hello.map { "v\($0.firmwareVersion)" } ?? "Not connected"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(appVersion)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .foregroundStyle(t.label2)
                        .textSelection(.enabled)
                } label: {
                    Text("App").foregroundStyle(t.label)
                }
                LabeledContent {
                    Text(firmwareVersion)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .foregroundStyle(t.label2)
                        .textSelection(.enabled)
                } label: {
                    Text("Radio firmware").foregroundStyle(t.label)
                }
            } header: {
                Text("Version").foregroundStyle(t.label2)
            }
            .listRowBackground(t.surface)
            .listRowSeparatorTint(t.sep)

            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(t.amber)
                    Text(store.txLicenseAcknowledged
                         ? "You confirmed you hold an amateur radio license."
                         : "You'll be asked to confirm you're licensed before your first voice transmission.")
                        .font(.subheadline)
                        .foregroundStyle(t.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Amateur radio license").foregroundStyle(t.label2)
            } footer: {
                Text("Receiving needs no license. Transmitting (voice, APRS messages, and position beacons) requires a valid amateur radio license, and you are responsible for following your country's rules for the frequencies and modes you use.")
                    .foregroundStyle(t.label2)
            }
            .listRowBackground(t.surface)
            .listRowSeparatorTint(t.sep)

            Section {
                Link(destination: Self.sourceURL) {
                    ExternalLinkLabel(title: "Source code", subtitle: "github.com/PilotJ357/kv4p-ht")
                }
                Link(destination: Self.upstreamURL) {
                    ExternalLinkLabel(title: "kv4p HT project", subtitle: "github.com/VanceVagell/kv4p-ht")
                }
                NavigationLink {
                    LicenseTextView()
                } label: {
                    LabeledContent {
                        Text("GPLv3").foregroundStyle(t.label2)
                    } label: {
                        Text("License").foregroundStyle(t.label)
                    }
                }
            } header: {
                Text("Open source").foregroundStyle(t.label2)
            } footer: {
                Text("Pocket HT is free software under the GNU General Public License v3. This iOS app is built on the kv4p HT project by Vance Vagell (KV4P) and uses no third-party libraries — only Apple system frameworks.")
                    .foregroundStyle(t.label2)
            }
            .listRowBackground(t.surface)
            .listRowSeparatorTint(t.sep)

            Section {
                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Text("Privacy policy").foregroundStyle(t.label)
                }
                Link(destination: Self.privacyURL) {
                    ExternalLinkLabel(title: "Privacy policy on the web")
                }
            } header: {
                Text("Privacy").foregroundStyle(t.label2)
            }
            .listRowBackground(t.surface)
            .listRowSeparatorTint(t.sep)
        }
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct ExternalLinkLabel: View {
    @Environment(\.theme) var t
    var title: String
    var subtitle: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(t.label)
                if let sub = subtitle {
                    Text(sub)
                        .font(.footnote)
                        .foregroundStyle(t.label2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right.square")
                .font(.subheadline)
                .foregroundStyle(t.label3)
                .accessibilityLabel("Opens in Safari")
        }
    }
}

// MARK: - License text

private struct LicenseTextView: View {
    @Environment(\.theme) var t

    // Split on blank lines so the ScrollView lays out paragraphs lazily
    // instead of one 35 KB Text, and unwrap the file's 80-column hard wraps
    // so paragraphs reflow to the screen width.
    private static let paragraphs: [String] = {
        guard let url = Bundle.main.url(forResource: "LICENSE-GPLv3", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return ["License text unavailable. See https://www.gnu.org/licenses/gpl-3.0.txt"] }
        return text.components(separatedBy: "\n\n")
            .map { para in
                para.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.paragraphs.enumerated()), id: \.offset) { _, p in
                    Text(p)
                        .font(.subheadline)
                        .foregroundStyle(t.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("GPLv3")
        .navigationBarTitleDisplayMode(.inline)
    }
}
