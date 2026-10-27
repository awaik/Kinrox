import SwiftUI

struct PairingView: View {
    let store: RemoteAppModel
    @State private var code = ""
    @State private var shakes = 0
    private var canEnter: Bool { store.connectionState == .awaitingPIN }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if store.connectionState == .incompatible {
                    ConnectionStatusView(store: store)
                } else {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 30, weight: .medium))
                        .frame(width: 72, height: 72)
                        .kinroxGlass(in: RoundedRectangle(cornerRadius: 24))
                    Text(L10n.text("Enter code")).font(KinroxFont.titleLarge()).padding(.top, 16)
                    Text(L10n.format("from the Mac screen “%@”", store.selected?.name ?? "Mac"))
                        .font(KinroxFont.body).foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center).padding(.top, 10)
                    CodeCells(code: code, length: 6, isLocked: !canEnter)
                        .modifier(Shake(animatableData: CGFloat(shakes))).padding(.top, 32)
                    Text(store.pairingMessage ?? store.failureMessage ?? instruction)
                        .font(KinroxFont.caption).foregroundStyle(Palette.flame)
                        .multilineTextAlignment(.center).padding(.vertical, 16)
                        .accessibilityIdentifier("pairing-status")
                    if store.connectionState == .failed || store.connectionState == .needsPairing {
                        Button(L10n.text("Request new code")) {
                            code = ""
                            store.beginPairing()
                        }
                        .padding(.bottom, 16)
                    }
                    if store.connectionState == .checkingPIN || store.connectionState == .connecting
                        || store.connectionState == .handshaking
                    {
                        ProgressView().padding(.bottom, 16)
                    }
                    Keypad(isEnabled: canEnter, press: press)
                    if store.isDemo {
                        Text(L10n.format("Demo: code %@", RemoteDemoStore.demoCode))
                            .font(KinroxFont.caption).foregroundStyle(Palette.textTertiary)
                            .padding(.top, 12)
                    }
                }
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 24).padding(.vertical, 24)
        }
        .background(EmberBackdrop())
        .navigationTitle(L10n.text("Pairing"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.pairingRevision) { _, _ in
            code = ""
            if store.pairingMessage != nil { withAnimation(.linear(duration: 0.4)) { shakes += 1 } }
        }
        .sensoryFeedback(.error, trigger: shakes)
    }
    private var instruction: String {
        switch store.connectionState {
        case .awaitingPIN: L10n.text("Code is shown on the Mac. Enter all six digits.")
        case .checkingPIN: L10n.text("Verifying code…")
        default: L10n.text("Connecting to Mac…")
        }
    }
    private func press(_ key: Keypad.Key) {
        guard canEnter else { return }
        switch key {
        case .digit(let digit):
            guard code.count < 6 else { return }
            code.append(digit)
            if code.count == 6 { store.submitPIN(code) }
        case .delete: if !code.isEmpty { code.removeLast() }
        }
    }
}

/// Six code digits; active highlighted in amber.
private struct CodeCells: View {
    let code: String
    let length: Int
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<length, id: \.self) { index in
                if index == length / 2 { Spacer().frame(width: 8) }
                cell(index)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format("Digits entered: %@ of %@", code.count.formatted(), length.formatted()))
    }

    private func cell(_ index: Int) -> some View {
        let digits = Array(code)
        let isActive = index == digits.count && !isLocked
        return ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Palette.glass)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isActive ? Palette.ember : Palette.hairline, lineWidth: isActive ? 2 : 1)
            if index < digits.count {
                Text(String(digits[index]))
                    .font(KinroxFont.timeLarge(30))
                    .foregroundStyle(Palette.textPrimary)
            } else if isActive {
                Capsule().fill(Palette.ember).frame(width: 2, height: 26)
            }
        }
        .frame(maxWidth: 48)
        .frame(height: 60)
        .shadow(color: isActive ? Palette.ember.opacity(0.4) : .clear, radius: 10)
    }
}

/// Horizontal shake of field on invalid code.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Remote keypad (Figma: `Key/Keypad`).
struct Keypad: View {
    enum Key: Hashable {
        case digit(Character)
        case delete
    }

    let isEnabled: Bool
    let press: (Key) -> Void
    @State private var taps = 0

    private let rows: [[Key?]] = [
        ["1", "2", "3"].map { .digit(Character($0)) },
        ["4", "5", "6"].map { .digit(Character($0)) },
        ["7", "8", "9"].map { .digit(Character($0)) },
        [nil, .digit("0"), .delete],
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { column in key(rows[row][column]) }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .sensoryFeedback(.selection, trigger: taps)
    }

    private func label(for key: Key) -> String {
        switch key {
        case .digit(let digit): String(digit)
        case .delete: L10n.text("Delete")
        }
    }

    @ViewBuilder
    private func key(_ key: Key?) -> some View {
        if let key {
            Button {
                taps += 1
                press(key)
            } label: {
                Group {
                    switch key {
                    case .digit(let digit):
                        Text(String(digit)).font(KinroxFont.titleLarge(24))
                    case .delete:
                        Image(systemName: "delete.left").font(.system(size: 22, weight: .medium))
                    }
                }
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    key == .delete ? Color.clear : Palette.glass,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .contentShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(for: key))
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 56)
        }
    }
}
