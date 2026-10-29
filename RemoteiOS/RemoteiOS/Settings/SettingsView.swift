import RemoteProtocol
import SwiftUI

struct SettingsView: View {
    let store: RemoteAppModel
    let switchMode: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if let player = store.selected {
                    Section {
                        Button(L10n.format("Forget %@", player.name), role: .destructive) {
                            store.forgetSelected()
                            dismiss()
                        }
                    } footer: {
                        Text(
                            L10n.text(
                                "Removes pairing on this iPhone. Remote access on Mac can be revoked in player settings."
                            )
                        )
                    }
                }
                Section(L10n.text("Network")) {
                    Button(L10n.text("Open iPhone Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
                Section {
                    Button(
                        store.isDemo ? L10n.text("Exit Demo") : L10n.text("Try Demo without Mac")
                    ) {
                        dismiss()
                        switchMode()
                    }
                } footer: {
                    Text(L10n.text("Demo uses mock data and does not connect to Mac."))
                }
                Section(L10n.text("About")) {
                    LabeledContent(
                        L10n.text("Version"),
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                            ?? "—")
                    LabeledContent(L10n.text("Protocol"), value: "v\(Version.current)")
                    Text(L10n.text("Local network only. No accounts or cloud."))
                        .foregroundStyle(Palette.textSecondary)
                    Text(ProjectLink.openSourceDescription)
                        .foregroundStyle(Palette.textSecondary)
                    ForEach(ProjectLink.allCases) { link in
                        Link(destination: link.url) {
                            HStack {
                                Text(link.title)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right")
                                    .font(.footnote)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Palette.elevated)
            .navigationTitle(L10n.text("Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
