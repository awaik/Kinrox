import RemoteProtocol
import SwiftUI

/// Screen 3 Remote: one-handed control in the dark (Figma: iPhone / Remote).
struct RemoteView: View {
    @Bindable var store: RemoteAppModel
    let switchMode: () -> Void
    @State private var showsRecents = false
    @State private var showsSettings = false
    @State private var showsScreensavers = false
    @State private var taps = 0

    private var state: PlayerState { store.state }

    var body: some View {
        // Position extrapolated each frame while Mac is playing.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    ConnectionStatusView(store: store)
                    TimelineView(
                        .animation(
                            minimumInterval: 1.0 / 30,
                            paused: state.paused || !store.controlsEnabled)
                    ) { _ in
                        content(position: store.position)
                    }
                    .id(store.epoch)
                    .disabled(!store.controlsEnabled)
                    .opacity(store.controlsEnabled ? 1 : 0.4)
                }
                .frame(minHeight: max(0, geometry.size.height - 16))
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 24)
        .background(EmberBackdrop())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("Settings"), systemImage: "slider.horizontal.3") {
                    showsSettings = true
                }
                .tint(Palette.textPrimary)
            }
        }
        .sheet(isPresented: $showsRecents) { RecentSheet(store: store) }
        .sheet(isPresented: $showsSettings) {
            SettingsView(store: store, switchMode: switchMode)
        }
        .navigationDestination(isPresented: $showsScreensavers) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        ConnectionStatusView(store: store)
                        ScreensaverControls(store: store)
                    }
                    .frame(minHeight: max(0, geometry.size.height - 16))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
            .background(EmberBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { header } }
            .onChange(of: state.screensaver, initial: true) { _, new in
                // Observe on the visible destination: SwiftUI may suspend updates
                // to the remote beneath it. Active Matrix occupies the remote itself.
                if new == .matrix { showsScreensavers = false }
            }
        }
        .alert(
            "Kinrox",
            isPresented: Binding(
                get: { store.commandError != nil && !showsRecents && !showsSettings },
                set: { if !$0 { store.commandError = nil } })
        ) {
            Button(L10n.text("Dismiss")) { store.commandError = nil }
        } message: {
            Text(store.commandError ?? "")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        #if DEBUG
            .task {
                if store.isDemo, UserDefaults.standard.string(forKey: "KinroxScreen") == "recents" {
                    showsRecents = true
                }
            }
        #endif
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text(store.selected?.name ?? "Mac")
                .lineLimit(1).truncationMode(.middle)
                .font(KinroxFont.title)
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: 6) {
                Circle().fill(store.controlsEnabled ? Palette.online : Palette.flame).frame(
                    width: 7, height: 7)
                Text(
                    store.isDemo
                        ? L10n.text("Online · demo")
                        : store.controlsEnabled ? L10n.text("Online") : L10n.text("Offline")
                )
                .font(KinroxFont.caption)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func content(position: Double) -> some View {
        if state.screensaver == .matrix {
            ScreensaverControls(store: store)
        } else if state.hasMedia {
            controls(position: position)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "play.rectangle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Palette.textTertiary)
                Text(L10n.text("Nothing is playing on Mac"))
                    .font(KinroxFont.title)
                    .foregroundStyle(Palette.textSecondary)
                PillButton(title: L10n.text("Recent"), systemImage: "clock.arrow.circlepath") {
                    showsRecents = true
                }
                .frame(maxWidth: 220)
                screensaverEntry
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func controls(position: Double) -> some View {
        let shown = store.scrubTarget ?? position
        let gestureEpoch = store.epoch
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(state.paused ? L10n.text("Paused") : L10n.text("Now Playing"))
                    .overlineStyle(Palette.ember)
                Text(state.title)
                    .font(KinroxFont.titleLarge(26))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TimeFormat.elapsed(shown, duration: state.duration))
                    .font(KinroxFont.timeLarge(store.scrubTarget == nil ? 48 : 52))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(store.scrubTarget == nil ? Palette.textPrimary : Palette.flame)
                    .contentTransition(.numericText())
                Text("/ " + TimeFormat.string(state.duration))
                    .font(KinroxFont.title.monospacedDigit())
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
            }
            .environment(\.layoutDirection, .leftToRight)
            .padding(.top, 26)
            RemoteScrubber(position: position, duration: state.duration, target: $store.scrubTarget)
            {
                taps += 1
                guard store.epoch == gestureEpoch else { return }
                store.seek(to: $0)
            }
            .padding(.top, 18)
            HStack {
                Text(TimeFormat.elapsed(shown, duration: state.duration))
                Spacer()
                Text(TimeFormat.remaining(position: shown, duration: state.duration))
            }
            .environment(\.layoutDirection, .leftToRight)
            .font(KinroxFont.caption.monospacedDigit())
            .foregroundStyle(Palette.textTertiary)
            .padding(.top, 8)
            Spacer(minLength: 20)
            transport.environment(\.layoutDirection, .leftToRight)
            Spacer(minLength: 20)
            HStack(spacing: 8) {
                ForEach([-30.0, -10, 10, 30], id: \.self) { seconds in
                    SeekButton(seconds: seconds) {
                        taps += 1
                        store.seek(by: seconds)
                    }

                }
            }
            .environment(\.layoutDirection, .leftToRight)
            VolumeBar(volume: state.volume) {
                guard store.epoch == gestureEpoch else { return }
                store.setVolume($0)
            }
            .padding(.top, 26)
            HStack(spacing: 12) {
                PillButton(
                    title: state.fullscreen ? L10n.text("Window") : L10n.text("Full Screen"),
                    systemImage: state.fullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    isOn: state.fullscreen
                ) {
                    taps += 1
                    store.toggleFullscreen()
                }
                PillButton(title: L10n.text("Recent"), systemImage: "clock.arrow.circlepath") {
                    showsRecents = true
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            screensaverEntry.padding(.top, 4)
        }
        .padding(.top, 12)
    }

    private var screensaverEntry: some View {
        Button {
            showsScreensavers = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle")
                Text(L10n.text("Screensavers"))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(KinroxFont.bodyStrong)
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 56)
            .kinroxGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(PressableStyle())
    }

    private var transport: some View {
        HStack(spacing: 28) {
            GlassIconButton(
                systemName: "backward.end.fill", label: L10n.text("Previous file"), size: 64,
                iconSize: 22,
                isEnabled: store.canPrevious
            ) {
                taps += 1
                store.previous()
            }
            Button {
                taps += 1
                store.togglePause()
            } label: {
                Image(systemName: state.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .offset(x: state.paused ? 3 : 0)
                    .frame(width: 100, height: 100)
                    .background(Palette.emberDiagonal, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.3)))
                    .shadow(color: Palette.ember.opacity(0.55), radius: 22, y: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(state.paused ? L10n.text("Play") : L10n.text("Pause"))
            GlassIconButton(
                systemName: "forward.end.fill", label: L10n.text("Next file"), size: 64,
                iconSize: 22,
                isEnabled: store.canNext
            ) {
                taps += 1
                store.next()
            }
        }
    }
}

/// Slight compression on press.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
