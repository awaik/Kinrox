import SwiftUI

/// Approved Figma setup 136:3536, pairing 137:3544 and recovery variants 137:3553–137:3570.
struct SoloistSettingsSection: View {
    @Bindable var setup: SoloistSetup
    @State private var key = ""
    @State private var document: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                setup.availability == .needsPairing
                    ? L10n.text("Pair Spotify with this Mac") : L10n.text("Spotify on this Mac")
            )
            .font(KinroxFont.titleLarge(22))
            if setup.showsKeyFields { keyFields }
            status
            if setup.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Spacer()
                    Button(L10n.text("Cancel")) { Task { await setup.cancel() } }
                }
            }
        }
        .font(KinroxFont.body).foregroundStyle(Palette.textPrimary)
        .padding(24).background(Palette.glass, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline))
        .onDisappear { key = "" }
        .sheet(isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } })) {
            SpotifyDocumentView(privacy: document == true)
        }
    }

    private var keyFields: some View {
        Group {
            Text(
                L10n.text(
                    "Spotify Premium is required. Create your personal Soloist API key in Spotify for Developers."
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            Link(
                destination: URL(string: "https://developer.spotify.com/dashboard/soloist")!
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Get a Soloist API key"))
                    Text("developer.spotify.com/dashboard/soloist").font(KinroxFont.monoDigits(13))
                }
            }.foregroundStyle(Palette.flame)
            SecureField(L10n.text("Personal Soloist API key"), text: $key)
                .textFieldStyle(.roundedBorder).disabled(setup.busy)
            Text(
                L10n.text(
                    "Your key stays in the Mac Keychain. While Soloist runs, other processes under your user account can read the key from its launch arguments."
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("Connection terms")) { document = false }
                Button(L10n.text("Privacy Policy")) { document = true }
            }
            Text(
                L10n.text(
                    "Soloist downloads directly from Spotify. After installation, select Kinrox once in Spotify on your iPhone."
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("Save key and set up Soloist")) {
                    setup.saveKeyAndInstall(key)
                    key = ""
                }.disabled(
                    key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || setup.busy)
                Spacer()
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch setup.availability {
        case .needsPairing:
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    L10n.text(
                        "Open Spotify on your iPhone. Connect iPhone and Mac to the same Wi-Fi network and allow Spotify to access the local network."
                    ))
                if setup.busy {
                    Text(L10n.text("Select this device in Spotify:") + "\n" + setup.deviceName)
                        .textSelection(.enabled)
                    Text(L10n.text("Waiting for pairing and account verification…"))
                } else {
                    Button(L10n.text("Start pairing")) { setup.pair() }
                }
                Text(
                    L10n.text(
                        "After pairing, you can close Spotify on your iPhone. Spotify on Mac is not required."
                    ))
            }.fixedSize(horizontal: false, vertical: true)
        case .downloading:
            Text(L10n.text("Downloading and verifying Soloist…")).font(KinroxFont.caption)
        case .ready:
            HStack {
                Label(L10n.text("Ready on this Mac"), systemImage: "checkmark.circle")
                Spacer()
                Button(L10n.text("Pair again")) { setup.pair() }.disabled(setup.busy)
                if setup.installation?.shouldOfferUpdate(at: Date()) == true {
                    Button(L10n.text("Update Soloist")) { setup.install() }.disabled(setup.busy)
                }
            }.font(KinroxFont.caption)
        case .expired:
            HStack {
                Text(L10n.text("Soloist has expired. Download a current version."))
                Button(L10n.text("Update Soloist")) { setup.install() }.disabled(setup.busy)
            }.font(KinroxFont.caption)
        case .notInstalled:
            Button(L10n.text("Download Soloist")) { setup.install() }.disabled(setup.busy)
        case .starting:
            Text(setup.availability.message ?? "").font(KinroxFont.caption)
        case .reconnecting, .externalTakeover:
            Text(setup.availability.message ?? "").font(KinroxFont.caption)
            recoveryButtons
        case .failed(let message):
            Text(L10n.text(message)).font(KinroxFont.caption).foregroundStyle(Palette.flame)
            recoveryButtons
        case .needsKey: EmptyView()
        }
    }

    @ViewBuilder private var recoveryButtons: some View {
        if setup.canRecoverPlayback {
            Button(L10n.text("Retry")) { setup.recover() }.disabled(setup.busy)
        }
        if setup.installation != nil, setup.hasKey {
            Button(L10n.text("Pair again")) { setup.pair() }.disabled(setup.busy)
            if setup.installation?.shouldOfferUpdate(at: Date()) == true {
                Button(L10n.text("Update Soloist")) { setup.install() }.disabled(setup.busy)
            }
        }
    }

}
