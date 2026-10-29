import SwiftUI

/// Welcome-screen banner, Figma page 05 component `Banner/Update`, state Available.
struct UpdateBanner: View {
    let center: UpdateCenter
    let update: AvailableUpdate

    var body: some View {
        HStack(spacing: 18) {
            UpdateBadge(size: 52, cornerRadius: 16, iconSize: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(L10n.text("A new version of Kinrox is available"))
                        .font(KinroxFont.title)
                        .foregroundStyle(Palette.textPrimary)
                    Text(update.version)
                        .font(KinroxFont.time)
                        .foregroundStyle(Palette.flame)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Palette.ember.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.flame.opacity(0.28)))
                }
                Text(
                    L10n.format(
                        "You have %@. It takes about a minute; recents and settings are kept.",
                        center.currentVersion)
                )
                .font(KinroxFont.body)
                .foregroundStyle(Palette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if update.releaseNotesURL != nil {
                    UpdatePillButton(title: L10n.text("What's New"), style: .secondary) {
                        center.showReleaseNotes()
                    }
                }
                UpdatePillButton(title: L10n.text("Update"), style: .primary) { center.install() }
                UpdateHideButton(size: 40, iconSize: 14) { center.hide() }
            }
            .fixedSize()
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 20))
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            shape.fill(Palette.elevated)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [Palette.ember.opacity(0.24), Palette.ember.opacity(0)],
                            startPoint: .leading, endPoint: UnitPoint(x: 0.62, y: 0.5)))
                )
                .overlay(shape.strokeBorder(Self.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 20)
                .shadow(color: Palette.ember.opacity(0.26), radius: 22, y: 10)
        }
        .accessibilityElement(children: .contain)
    }

    private static let stroke = LinearGradient(
        stops: [
            .init(color: Palette.flame.opacity(0.7), location: 0),
            .init(color: Palette.textPrimary.opacity(0.18), location: 0.45),
            .init(color: Palette.hairline, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
}

/// Paused-player pill, Figma page 05 component `Banner/Update Compact`, state Available.
struct UpdatePill: View {
    let center: UpdateCenter
    let update: AvailableUpdate

    var body: some View {
        HStack(spacing: 10) {
            UpdateBadge(size: 28, cornerRadius: 14, iconSize: 14)
            Text(L10n.format("Kinrox %@ is available", update.version))
                .font(KinroxFont.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            UpdatePillButton(title: L10n.text("Update"), style: .primary, small: true) {
                center.install()
            }
            UpdateHideButton(size: 28, iconSize: 10) { center.hide() }
        }
        .padding(6)
        .background {
            Capsule().fill(Color(red: 0.04, green: 0.03, blue: 0.03).opacity(0.62))
                .overlay(
                    Capsule().fill(
                        LinearGradient(
                            colors: [Palette.ember.opacity(0.22), Palette.ember.opacity(0)],
                            startPoint: .leading, endPoint: UnitPoint(x: 0.7, y: 0.5)))
                )
                .overlay(Capsule().strokeBorder(Palette.strokeGlass))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 12)
                .shadow(color: Palette.ember.opacity(0.22), radius: 14, y: 6)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

/// Fire-gradient square with the upgrade arrow.
private struct UpdateBadge: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let iconSize: CGFloat

    var body: some View {
        Image(systemName: "arrow.up.circle")
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: size, height: size)
            .background(
                Palette.emberDiagonal,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(color: Palette.ember.opacity(0.5), radius: size / 5, y: size / 9)
            .accessibilityHidden(true)
    }
}

/// Figma component `Button/Pill`.
struct UpdatePillButton: View {
    enum Style { case primary, secondary }

    let title: String
    let style: Style
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(small ? KinroxFont.caption : KinroxFont.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, small ? 14 : 20)
                .padding(.vertical, small ? 6 : 10)
                .background {
                    switch style {
                    case .primary:
                        Capsule().fill(Palette.emberGradient)
                            .shadow(
                                color: Palette.ember.opacity(small ? 0.4 : 0.45),
                                radius: small ? 7 : 12, y: small ? 4 : 8)
                    case .secondary:
                        Capsule().fill(Palette.glass)
                            .overlay(Capsule().strokeBorder(Palette.hairline))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// × hides the reminder for now; it never cancels anything.
private struct UpdateHideButton: View {
    let size: CGFloat
    let iconSize: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: size, height: size)
                .background(isHovering ? Palette.glassStrong : Palette.glass, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { isHovering = $0 }
        .help(L10n.text("Hide update reminder"))
        .accessibilityLabel(L10n.text("Hide update reminder"))
    }
}
