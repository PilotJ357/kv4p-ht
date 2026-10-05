import SwiftUI

// MARK: - About
// Version info, source/license (GPLv3 §6: binary distribution must carry the
// license and point to the Corresponding Source), and the amateur-license
// notice. LICENSE-GPLv3.txt is a copy of LICENSE at the repo root.

struct AboutView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
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
        ScrollView {
            VStack(spacing: 4) {
                ListGroupView(header: "Version") {
                    AboutValueRow(label: "App", value: appVersion, isLast: false)
                    AboutValueRow(label: "Radio firmware", value: firmwareVersion, isLast: true)
                }

                ListGroupView(header: "Amateur radio license",
                              footer: "Receiving needs no license. Transmitting (voice, APRS messages, and position beacons) requires a valid amateur radio license, and you are responsible for following your country's rules for the frequencies and modes you use.") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(t.amber)
                        Text(store.txLicenseAcknowledged
                             ? "You confirmed you hold an amateur radio license."
                             : "You'll be asked to confirm you're licensed before your first voice transmission.")
                            .font(.system(size: 15))
                            .foregroundStyle(t.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                ListGroupView(header: "Open source",
                              footer: "Pocket HT is free software under the GNU General Public License v3. This iOS app is built on the kv4p HT project by Vance Vagell (KV4P) and uses no third-party libraries — only Apple system frameworks.") {
                    Button { openURL(Self.sourceURL) } label: {
                        ListRow(title: "Source code", subtitle: "github.com/PilotJ357/kv4p-ht",
                                isLast: false, accessory: ExternalLinkIcon() as (any View))
                    }
                    .buttonStyle(.plain)
                    Button { openURL(Self.upstreamURL) } label: {
                        ListRow(title: "kv4p HT project", subtitle: "github.com/VanceVagell/kv4p-ht",
                                isLast: false, accessory: ExternalLinkIcon() as (any View))
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        LicenseTextView()
                    } label: {
                        ListRow(title: "License", value: "GPLv3", isLast: true)
                    }
                    .buttonStyle(.plain)
                }

                ListGroupView(header: "Privacy") {
                    NavigationLink {
                        PrivacyPolicyView(backLabel: nil)
                    } label: {
                        ListRow(title: "Privacy policy", isLast: false)
                    }
                    .buttonStyle(.plain)
                    Button { openURL(Self.privacyURL) } label: {
                        ListRow(title: "Privacy policy on the web",
                                isLast: true, accessory: ExternalLinkIcon() as (any View))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 32)
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("More")
                            .font(.system(size: 17))
                    }
                }
            }
        }
    }
}

private struct ExternalLinkIcon: View {
    @Environment(\.theme) var t

    var body: some View {
        Image(systemName: "arrow.up.right.square")
            .font(.system(size: 15))
            .foregroundStyle(t.label3)
            .accessibilityLabel("Opens in Safari")
    }
}

private struct AboutValueRow: View {
    @Environment(\.theme) var t
    var label: String
    var value: String
    var isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 15.5))
                    .foregroundStyle(t.label)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
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
                        .font(.system(size: 14))
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
