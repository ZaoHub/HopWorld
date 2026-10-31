import Foundation

struct SubscriptionDateTemplate: Equatable, Sendable {
    let template: String

    func resolve(date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return template
        }

        let yyyy = String(format: "%04d", year)
        let yy = String(format: "%02d", year % 100)
        let MM = String(format: "%02d", month)
        let M = "\(month)"
        let dd = String(format: "%02d", day)
        let d = "\(day)"
        let yyyyMMdd = "\(yyyy)\(MM)\(dd)"

        // Longer tokens first to avoid partial replacements.
        return template
            .replacingOccurrences(of: "{yyyyMMdd}", with: yyyyMMdd)
            .replacingOccurrences(of: "{yyyy-MM-dd}", with: "\(yyyy)-\(MM)-\(dd)")
            .replacingOccurrences(of: "{yyyy_MM_dd}", with: "\(yyyy)_\(MM)_\(dd)")
            .replacingOccurrences(of: "{yyyy}", with: yyyy)
            .replacingOccurrences(of: "{yy}", with: yy)
            .replacingOccurrences(of: "{MM}", with: MM)
            .replacingOccurrences(of: "{M}", with: M)
            .replacingOccurrences(of: "{dd}", with: dd)
            .replacingOccurrences(of: "{d}", with: d)
    }
}

struct DateTemplateDetection: Equatable, Sendable {
    var originalURL: String
    var template: String
    var detected: Bool
    var matchedDateText: String?

    func preview(for date: Date, timeZone: TimeZone) -> String {
        SubscriptionDateTemplate(template: template).resolve(date: date, timeZone: timeZone)
    }
}

enum SubscriptionDateTemplateDetector {
    private static let compactDatePattern = #"(?<!\d)(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)"#

    static func detect(from urlString: String) -> DateTemplateDetection {
        guard let regex = try? NSRegularExpression(pattern: compactDatePattern) else {
            return DateTemplateDetection(originalURL: urlString, template: urlString, detected: false, matchedDateText: nil)
        }

        let range = NSRange(urlString.startIndex..., in: urlString)
        guard let match = regex.firstMatch(in: urlString, range: range),
              match.numberOfRanges >= 4,
              let fullRange = Range(match.range(at: 0), in: urlString),
              let yearRange = Range(match.range(at: 1), in: urlString),
              let monthRange = Range(match.range(at: 2), in: urlString),
              let dayRange = Range(match.range(at: 3), in: urlString)
        else {
            let splitDate = detectYearMonthDirectory(from: urlString)
            return splitDate.detected ? splitDate : detectSeparatedFormats(from: urlString)
        }

        let year = String(urlString[yearRange])
        let month = String(urlString[monthRange])
        let day = String(urlString[dayRange])
        let matched = String(urlString[fullRange])

        var template = urlString
        template.replaceSubrange(fullRange, with: "{yyyyMMdd}")

        // Convert /yyyy/MM/ when it matches the compact date.
        let slashPattern = "/\(year)/\(month)/"
        if template.contains(slashPattern) {
            template = template.replacingOccurrences(of: slashPattern, with: "/{yyyy}/{MM}/")
        }

        let dashPattern = "\(year)-\(month)-\(day)"
        if template.contains(dashPattern) {
            template = template.replacingOccurrences(of: dashPattern, with: "{yyyy-MM-dd}")
        }

        let underscorePattern = "\(year)_\(month)_\(day)"
        if template.contains(underscorePattern) {
            template = template.replacingOccurrences(of: underscorePattern, with: "{yyyy_MM_dd}")
        }

        return DateTemplateDetection(
            originalURL: urlString,
            template: template,
            detected: template != urlString,
            matchedDateText: matched
        )
    }

    private static func detectYearMonthDirectory(from urlString: String) -> DateTemplateDetection {
        let unchanged = DateTemplateDetection(originalURL: urlString, template: urlString, detected: false, matchedDateText: nil)
        let pathEnd = urlString.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? urlString.endIndex
        // The filename month must match the directory month; never rewrite query tokens.
        let pattern = #"/(20\d{2})(0[1-9]|1[0-2])/\2(0[1-9]|[12]\d|3[01])(?=[^\d/?#][^/?#]*$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..<pathEnd, in: urlString)),
              let fullRange = Range(match.range, in: urlString),
              let yearRange = Range(match.range(at: 1), in: urlString),
              let monthRange = Range(match.range(at: 2), in: urlString),
              let dayRange = Range(match.range(at: 3), in: urlString),
              let year = Int(urlString[yearRange]), let month = Int(urlString[monthRange]), let day = Int(urlString[dayRange])
        else { return unchanged }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return unchanged }
        var template = urlString
        template.replaceSubrange(fullRange, with: "/{yyyy}{MM}/{MM}{dd}")
        return DateTemplateDetection(originalURL: urlString, template: template, detected: true,
                                     matchedDateText: String(format: "%04d%02d%02d", year, month, day))
    }

    private static func detectSeparatedFormats(from urlString: String) -> DateTemplateDetection {
        let patterns: [(String, String)] = [
            (#"(?<!\d)(20\d{2})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])(?!\d)"#, "{yyyy-MM-dd}"),
            (#"(?<!\d)(20\d{2})_(0[1-9]|1[0-2])_(0[1-9]|[12]\d|3[01])(?!\d)"#, "{yyyy_MM_dd}"),
            (#"(?<!\d)(20\d{2})/(0[1-9]|1[0-2])/(0[1-9]|[12]\d|3[01])(?!\d)"#, "{yyyy}/{MM}/{dd}")
        ]

        for (pattern, token) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
                  let fullRange = Range(match.range(at: 0), in: urlString)
            else { continue }

            var template = urlString
            template.replaceSubrange(fullRange, with: token)
            return DateTemplateDetection(
                originalURL: urlString,
                template: template,
                detected: true,
                matchedDateText: String(urlString[fullRange])
            )
        }

        return DateTemplateDetection(originalURL: urlString, template: urlString, detected: false, matchedDateText: nil)
    }
}
