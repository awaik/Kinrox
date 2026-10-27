import Foundation

extension RecentItem {
    var fileExtension: String { (title as NSString).pathExtension.uppercased() }

    /// "Yesterday · MKV" or "File not found" for unavailable item.
    func subtitle(available: Bool, now: Date = Date()) -> String {
        guard available else { return L10n.text("File not found") }
        var parts = [Self.relativeDate(openedAt, now: now)]
        if !fileExtension.isEmpty { parts.append(fileExtension) }
        return parts.joined(separator: " · ")
    }

    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return L10n.text("Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return L10n.text("Yesterday")
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = Date.FormatStyle.dateTime.day().month(.wide)
            .locale(.current)
        return sameYear ? date.formatted(style) : date.formatted(style.year())
    }
}
