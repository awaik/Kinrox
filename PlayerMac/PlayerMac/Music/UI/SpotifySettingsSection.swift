import SpotifyWebAPI
import SwiftUI

struct SpotifySettingsSection: View {
    @Bindable var account: SpotifyAccount
    @State private var document: Bool?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spotify").font(KinroxFont.bodyStrong)
            Text(
                L10n.text(
                    "Optional connection on Mac. Spotify Premium and your own developer app are required."
                )
            )
            .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
            TextField(L10n.text("Spotify Client ID"), text: $account.clientID)
                .textFieldStyle(.roundedBorder).disabled(account.connected || account.isConnecting)
            Text("Redirect URI: " + SpotifyAuthorization.redirect)
                .font(KinroxFont.monoDigits(11)).textSelection(.enabled)
            Text(
                L10n.text(
                    "Spotify access: library, playback, favorites and editable playlists. Removing a favorite also removes it from editable playlists."
                )
            )
            .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
            Text(
                L10n.text(
                    "Credentials stay in the Mac Keychain. Disconnect clears local Spotify data and keeps Spotify playlists. No Kinrox server or analytics."
                )
            )
            .font(KinroxFont.caption).foregroundStyle(Palette.textSecondary)
            HStack {
                Button(L10n.text("Connection terms")) { document = false }
                Button(L10n.text("Privacy Policy")) { document = true }
                if let documents = SpotifyDocuments.bundled {
                    Text(documents.language).font(KinroxFont.caption)
                }
            }
            if !account.connected {
                Toggle(
                    L10n.text(
                        "I accept the Spotify connection terms and have read the privacy policy."),
                    isOn: $account.termsAccepted
                )
                .disabled(account.isConnecting)
            }
            HStack {
                if let name = account.accountName {
                    Circle().fill(Palette.online).frame(width: 7, height: 7)
                    Text(name)
                }
                Spacer()
                if account.connected || account.isConnecting || account.hasStoredConnection {
                    Button(L10n.text("Disconnect")) { account.disconnect() }
                }
                if !account.connected && !account.isConnecting {
                    Button(L10n.text("Connect Spotify")) { account.connect() }.tint(Palette.ember)
                        .disabled(!account.termsAccepted || SpotifyDocuments.bundled == nil)
                }
                if account.isConnecting { ProgressView().controlSize(.small) }
            }
            if let error = account.errorMessage {
                Text(error).font(KinroxFont.caption).foregroundStyle(Palette.flame)
            }
        }.padding(18).background(Palette.glass, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
            .sheet(
                isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } })
            ) {
                SpotifyDocumentView(privacy: document == true)
            }
    }
}
