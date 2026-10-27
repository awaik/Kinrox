import RemoteProtocol
import SwiftUI

/// Screen 4 Recent: bottom sheet, tap opens file on Mac and closes sheet.
struct RecentSheet: View {
    let store: RemoteAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Recent"))
                    .font(KinroxFont.titleLarge())
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                GlassIconButton(
                    systemName: "xmark", label: L10n.text("Close"), size: 36, iconSize: 14
                ) {
                    dismiss()
                }
            }
            .padding(.top, 24)
            if let error = store.commandError {
                Text(error)
                    .font(KinroxFont.caption)
                    .foregroundStyle(Palette.flame)
                    .accessibilityIdentifier("recent-command-error")
            }
            ScrollView {
                VStack(spacing: 0) {
                    if store.recents.isEmpty {
                        Text(L10n.text("No recent files on Mac yet")).padding(.vertical, 24)
                    }
                    ForEach(store.recents) { item in
                        row(item)
                        if item.id != store.recents.last?.id {
                            Divider().overlay(Palette.hairline)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ item: RecentItem) -> some View {
        let isCurrent = item.title == store.state.title && store.state.hasMedia
        return Button {
            waiting = true
            store.commandError = nil
            store.open(item) { accepted in
                waiting = false
                if accepted { dismiss() }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(
                        isCurrent
                            ? AnyShapeStyle(Palette.emberDiagonal) : AnyShapeStyle(Palette.glass),
                        in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(KinroxFont.bodyStrong)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(item, isCurrent: isCurrent))
                        .font(KinroxFont.caption.monospacedDigit())
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.available || !store.controlsEnabled || waiting)
        .opacity(item.available ? 1 : 0.4)
    }

    private func subtitle(_ item: RecentItem, isCurrent: Bool) -> String {
        guard item.available else { return L10n.text("File not found") }
        let duration = item.duration.map { TimeFormat.format($0) } ?? L10n.text("Unknown duration")
        return duration
    }
}
