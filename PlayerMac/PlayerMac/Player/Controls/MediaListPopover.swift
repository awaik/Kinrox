import SwiftUI

/// Row in popover list: folder playlist or recent files.
struct MediaListRow: View {
    let title: String
    let subtitle: String
    var isCurrent = false
    var isAvailable = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "play.fill" : "film")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.textPrimary : Palette.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(
                                isCurrent
                                    ? AnyShapeStyle(Palette.emberGradient)
                                    : AnyShapeStyle(Palette.glass)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(KinroxFont.bodyStrong)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(KinroxFont.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(isHovering ? Palette.glass : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1 : 0.4)
        .onHover { isHovering = $0 }
    }
}

/// Popover list wrapper with Kinrox style title.
struct MediaListPopover<Rows: View>: View {
    let title: String
    let emptyText: String
    let isEmpty: Bool
    var headerActionTitle: String? = nil
    var footerActionTitle: String? = nil
    var headerAction: (() -> Void)? = nil
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).overlineStyle()
                Spacer()
                if let headerActionTitle, let headerAction {
                    Button("\(headerActionTitle)  →", action: headerAction)
                        .buttonStyle(.plain)
                        .font(KinroxFont.caption)
                        .foregroundStyle(Palette.flame)
                }
            }
            .padding(.horizontal, 8)
            if isEmpty {
                Text(emptyText)
                    .font(KinroxFont.body)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(spacing: 2) { rows() }
                }
                .frame(maxHeight: 360)
            }
            if let footerTitle = footerActionTitle ?? headerActionTitle, let headerAction {
                Button(action: headerAction) {
                    HStack {
                        Text(footerTitle)
                            .font(KinroxFont.bodyStrong)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("Esc  →")
                            .font(KinroxFont.caption)
                            .foregroundStyle(Palette.flame)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Palette.ember.opacity(0.4), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("popover-open-video-home-button")
            }
        }
        .padding(12)
        .frame(width: 340)
        .preferredColorScheme(.dark)
    }
}
