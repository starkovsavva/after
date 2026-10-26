import Foundation

/// Legacy wording stays untouched. Relative deadlines are interpreted against
/// the source's creation date, never against the day the user reopens the app.
public enum TaskDueDate {
    public static func resolve(_ raw: String, reference: Date? = nil, calendar userCalendar: Calendar = .current) -> Date? {
        let calendar = gregorian(userCalendar)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= 120 else { return nil }
        if let date = absolute(text, calendar: calendar) { return date }
        guard let reference else { return nil }
        let day = calendar.startOfDay(for: reference)
        let wording = text.replacingOccurrences(of: "ё", with: "е")
        let plain = ["до ", "к ", "во ", "в "].first(where: wording.hasPrefix).map { String(wording.dropFirst($0.count)) } ?? wording
        switch plain {
        case "сегодня", "сегодняшнему дню": return day
        case "завтра", "завтрашнему дню": return calendar.date(byAdding: .day, value: 1, to: day)
        case "послезавтра": return calendar.date(byAdding: .day, value: 2, to: day)
        default: break
        }
        let weekdays: [String: Int] = ["воскресенье": 1, "воскресенья": 1, "воскресенью": 1,
            "понедельник": 2, "понедельника": 2, "понедельнику": 2,
            "вторник": 3, "вторника": 3, "вторнику": 3,
            "среда": 4, "среду": 4, "среды": 4, "среде": 4,
            "четверг": 5, "четверга": 5, "четвергу": 5,
            "пятница": 6, "пятницу": 6, "пятницы": 6, "пятнице": 6,
            "суббота": 7, "субботу": 7, "субботы": 7, "субботе": 7]
        if let weekday = weekdays[plain] {
            let offset = (weekday - calendar.component(.weekday, from: day) + 7) % 7
            return calendar.date(byAdding: .day, value: offset, to: day)
        }
        return nil
    }

    public static func storage(_ date: Date, calendar userCalendar: Calendar = .current) -> String {
        let calendar = gregorian(userCalendar)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    public static func display(_ raw: String, reference: Date? = nil, calendar userCalendar: Calendar = .current) -> String {
        let calendar = gregorian(userCalendar)
        guard let date = resolve(raw, reference: reference, calendar: calendar) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private static func gregorian(_ supplied: Calendar) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = supplied.timeZone; calendar.locale = supplied.locale
        return calendar
    }

    private static func absolute(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
           parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            return checked(year: year, month: month, day: day, calendar: calendar)
        }
        let numeric = text.split(separator: ".", omittingEmptySubsequences: false)
        if numeric.count == 3, numeric.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }), numeric[2].count == 4,
           let day = Int(numeric[0]), let month = Int(numeric[1]), let year = Int(numeric[2]) {
            return checked(year: year, month: month, day: day, calendar: calendar)
        }
        let months = ["января": 1, "февраля": 2, "марта": 3, "апреля": 4, "мая": 5, "июня": 6,
                      "июля": 7, "августа": 8, "сентября": 9, "октября": 10, "ноября": 11, "декабря": 12]
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 3, let day = Int(words[0]), let month = months[words[1]], let year = Int(words[2]) {
            return checked(year: year, month: month, day: day, calendar: calendar)
        }
        return nil
    }

    private static func checked(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let value = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: value)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        return value
    }
}
