// Prints the Lock Screen date and a "2 h 14 min" duration for each locale argument
// as JSON. Gregorian calendar and Latin digits match the rest of the screenshot UI.
import Foundation

var parts = DateComponents()
parts.year = 2026
parts.month = 11
parts.day = 11
parts.hour = 12
var gregorian = Calendar(identifier: .gregorian)
gregorian.timeZone = TimeZone(identifier: "UTC")!
let date = gregorian.date(from: parts)!
var out: [String: [String: String]] = [:]
for id in CommandLine.arguments.dropFirst() {
    let locale = Locale(identifier: id.replacingOccurrences(of: "-", with: "_") + "@numbers=latn")
    var calendar = gregorian
    calendar.locale = locale
    let dates = DateFormatter()
    dates.locale = locale
    dates.calendar = calendar
    dates.timeZone = gregorian.timeZone
    dates.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
    let durations = DateComponentsFormatter()
    durations.unitsStyle = .abbreviated
    durations.allowedUnits = [.hour, .minute]
    durations.calendar = calendar
    out[id] = ["date": dates.string(from: date), "duration": durations.string(from: 8040)!]
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
print(String(data: try encoder.encode(out), encoding: .utf8)!)
