import Foundation

/// Pulls today's strip URL out of a GoComics HTML page.
///
/// As of October 2026 the dated page (for example
/// `https://www.gocomics.com/calvinandhobbes/2026/10/14`) exposes the strip as:
/// - `<meta property="og:image" content="https://featureassets.gocomics.com/assets/{id}">`
/// - the same URL in `twitter:image`
/// - a JSON-LD `ImageObject` whose `contentUrl` is that asset and whose
///   `datePublished` is like `October 14, 2026`
///
/// The page also embeds other strips (related comics, badges, splash art).
/// Those are ignored unless the date matches. Query strings such as
/// `?optimizer=image&width=210` are stripped so the original asset is downloaded.
struct ParsedStrip {
    var imageURL: URL
    var day: Date?
    var source: String
}

struct JSONLDHit {
    var rawDate: String
    var imageURL: URL?
}

enum StripHTML {
    static func extractImageURL(html: String, day: Date, calendar: Calendar) -> URL? {
        let identified = pageIdentifies(day: day, html: html, calendar: calendar)

        if identified {
            let metaKeys = [
                ("property", "og:image"),
                ("name", "twitter:image"),
                ("property", "vf:image")
            ]
            for (attribute, name) in metaKeys {
                for content in metaContents(html, attribute: attribute, equals: name) {
                    if let url = normalizeFeatureAsset(content) {
                        return url
                    }
                }
            }
        }

        if let jsonURL = jsonLDImageURL(html: html, day: day, calendar: calendar) {
            return jsonURL
        }

        if identified, let first = firstFeatureAsset(in: html) {
            return first
        }
        return nil
    }

    /// The daily page's share image, or the newest JSON-LD strip close to `preferredDay`.
    /// Related strips from the 1980s stay out because their dates are far away.
    static func extractBest(html: String, preferredDay: Date, calendar: Calendar) -> ParsedStrip? {
        if let exact = extractImageURL(html: html, day: preferredDay, calendar: calendar) {
            return ParsedStrip(imageURL: exact, day: preferredDay, source: "exact")
        }

        let metaKeys = [
            ("property", "og:image", "og:image"),
            ("name", "twitter:image", "twitter:image"),
            ("property", "vf:image", "vf:image")
        ]
        for (attribute, name, source) in metaKeys {
            for content in metaContents(html, attribute: attribute, equals: name) {
                guard let url = normalizeFeatureAsset(content) else { continue }
                let dated = pageDate(html: html, calendar: calendar)
                if let dated, !isRecent(dated, preferred: preferredDay, calendar: calendar) {
                    continue
                }
                return ParsedStrip(imageURL: url, day: dated, source: source)
            }
        }

        let hits = jsonLDHits(html: html)
        let recent = hits.compactMap { hit -> (Date, URL)? in
            guard let url = hit.imageURL, let day = parseDay(in: hit.rawDate, calendar: calendar) else { return nil }
            guard isRecent(day, preferred: preferredDay, calendar: calendar) else { return nil }
            return (day, url)
        }
        if let match = recent.first(where: { calendar.isDate($0.0, inSameDayAs: preferredDay) }) {
            return ParsedStrip(imageURL: match.1, day: match.0, source: "jsonld")
        }
        if let newest = recent.max(by: { $0.0 < $1.0 }) {
            return ParsedStrip(imageURL: newest.1, day: newest.0, source: "jsonld-newest")
        }
        return nil
    }

    static func describeJSONLD(html: String) -> String {
        let hits = jsonLDHits(html: html)
        if hits.isEmpty { return "none" }
        let parts = hits.prefix(6).map { hit -> String in
            let date = hit.rawDate.isEmpty ? "undated" : hit.rawDate
            let asset = hit.imageURL?.lastPathComponent ?? "no-image"
            return "\(date) \(asset)"
        }
        let text = parts.joined(separator: " | ")
        if text.count <= 420 { return text }
        return String(text.prefix(420))
    }

    static func pageDate(html: String, calendar: Calendar) -> Date? {
        if let ogURL = metaContents(html, attribute: "property", equals: "og:url").first,
           let day = parseDay(in: ogURL, calendar: calendar) {
            return day
        }
        if let canonical = linkHref(html, rel: "canonical"),
           let day = parseDay(in: canonical, calendar: calendar) {
            return day
        }
        if let title = metaContents(html, attribute: "property", equals: "og:title").first,
           let day = parseDay(in: title, calendar: calendar) {
            return day
        }
        return nil
    }

    static func isRecent(_ day: Date, preferred: Date, calendar: Calendar) -> Bool {
        let target = calendar.startOfDay(for: preferred)
        guard let earliest = calendar.date(byAdding: .day, value: -3, to: target),
              let latest = calendar.date(byAdding: .day, value: 1, to: target) else {
            return false
        }
        let start = calendar.startOfDay(for: day)
        return start >= earliest && start <= latest
    }

    static func parseDay(in text: String, calendar: Calendar) -> Date? {
        if let pathDay = dayFromPath(text, calendar: calendar) {
            return pathDay
        }
        if let iso = isoDay(in: text, calendar: calendar) {
            return iso
        }
        return longDay(in: text, calendar: calendar)
    }

    static func pageIdentifies(day: Date, html: String, calendar: Calendar) -> Bool {
        let suffix = datePathSuffix(day, calendar: calendar)
        if let ogURL = metaContents(html, attribute: "property", equals: "og:url").first {
            return pathHasDateSuffix(ogURL, suffix: suffix)
        }
        if let canonical = linkHref(html, rel: "canonical") {
            return pathHasDateSuffix(canonical, suffix: suffix)
        }
        let longDate = longDateText(day, calendar: calendar)
        let title = metaContents(html, attribute: "property", equals: "og:title").first ?? ""
        return title.contains(longDate)
    }

    static func normalizeFeatureAsset(_ raw: String) -> URL? {
        let decoded = decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: decoded),
              let host = components.host?.lowercased(),
              host == "featureassets.gocomics.com" else {
            return nil
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0].lowercased() == "assets" else { return nil }
        let id = parts[1]
        guard (16...64).contains(id.count), id.allSatisfy(\.isHexDigit) else { return nil }
        var cleaned = URLComponents()
        cleaned.scheme = "https"
        cleaned.host = "featureassets.gocomics.com"
        cleaned.path = "/assets/\(id)"
        return cleaned.url
    }

    static func longDateText(_ day: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: day)
    }

    static func isoDateText(_ day: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    static func datePathSuffix(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let dayNumber = parts.day ?? 0
        return String(format: "/%04d/%02d/%02d", year, month, dayNumber)
    }

    // MARK: - HTML

    static func metaContents(_ html: String, attribute: String, equals expected: String) -> [String] {
        var results: [String] = []
        var search = html.startIndex
        while let open = html.range(of: "<meta", options: [.caseInsensitive], range: search..<html.endIndex) {
            let next = open.upperBound
            if next < html.endIndex {
                let boundary = html[next]
                let isTag = boundary == " " || boundary == "\n" || boundary == "\t" || boundary == ">" || boundary == "/"
                guard isTag, let close = html.range(of: ">", range: next..<html.endIndex) else {
                    search = next
                    continue
                }
                let tag = String(html[open.lowerBound..<close.upperBound])
                if let found = htmlAttribute(attribute, in: tag),
                   found.caseInsensitiveCompare(expected) == .orderedSame,
                   let content = htmlAttribute("content", in: tag) {
                    results.append(decodeHTMLEntities(content))
                }
                search = close.upperBound
            } else {
                break
            }
        }
        return results
    }

    static func linkHref(_ html: String, rel expected: String) -> String? {
        var search = html.startIndex
        while let open = html.range(of: "<link", options: [.caseInsensitive], range: search..<html.endIndex) {
            let next = open.upperBound
            guard next < html.endIndex else { return nil }
            let boundary = html[next]
            let isTag = boundary == " " || boundary == "\n" || boundary == "\t" || boundary == ">" || boundary == "/"
            guard isTag, let close = html.range(of: ">", range: next..<html.endIndex) else {
                search = html.index(after: open.lowerBound)
                continue
            }
            let tag = String(html[open.lowerBound..<close.upperBound])
            if let rel = htmlAttribute("rel", in: tag),
               rel.caseInsensitiveCompare(expected) == .orderedSame,
               let href = htmlAttribute("href", in: tag) {
                return decodeHTMLEntities(href)
            }
            search = close.upperBound
        }
        return nil
    }

    static func htmlAttribute(_ name: String, in tag: String) -> String? {
        let chars = Array(tag)
        let nameChars = Array(name.lowercased())
        guard chars.count > nameChars.count + 2 else { return nil }
        var index = 0
        while index + nameChars.count + 1 < chars.count {
            let boundary: Bool
            if index == 0 {
                boundary = false
            } else {
                let before = chars[index - 1]
                boundary = before == " " || before == "\n" || before == "\t" || before == "/"
            }
            if boundary {
                var matches = true
                for offset in 0..<nameChars.count {
                    if String(chars[index + offset]).lowercased() != String(nameChars[offset]) {
                        matches = false
                        break
                    }
                }
                if matches, chars[index + nameChars.count] == "=" {
                    var cursor = index + nameChars.count + 1
                    while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
                        cursor += 1
                    }
                    if cursor < chars.count {
                        let quote = chars[cursor]
                        if quote == "\"" || quote == "'" {
                            cursor += 1
                            var value = ""
                            while cursor < chars.count, chars[cursor] != quote {
                                value.append(chars[cursor])
                                cursor += 1
                            }
                            if cursor < chars.count, chars[cursor] == quote {
                                return value
                            }
                        }
                    }
                }
            }
            index += 1
        }
        return nil
    }

    static func decodeHTMLEntities(_ string: String) -> String {
        var result = string.replacingOccurrences(of: "&amp;", with: "&")
        let named = [
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return decodeNumericEntities(result)
    }

    static func pathHasDateSuffix(_ urlString: String, suffix: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return false }
        return components.path.hasSuffix(suffix)
    }

    // MARK: - JSON-LD

    static func jsonLDImageURL(html: String, day: Date, calendar: Calendar) -> URL? {
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            var urls: [URL] = []
            collectFeatureURLs(from: json, day: day, calendar: calendar, into: &urls)
            if let first = urls.first {
                return first
            }
        }
        return nil
    }

    private static func jsonLDBlocks(in html: String) -> [String] {
        let needle = "application/ld+json"
        var blocks: [String] = []
        var search = html.startIndex
        while let found = html.range(of: needle, options: [.caseInsensitive], range: search..<html.endIndex) {
            guard let open = html.range(of: ">", range: found.upperBound..<html.endIndex),
                  let close = html.range(of: "</script", options: [.caseInsensitive], range: open.upperBound..<html.endIndex) else {
                break
            }
            blocks.append(String(html[open.upperBound..<close.lowerBound]))
            search = close.upperBound
        }
        return blocks
    }

    private static func collectFeatureURLs(from json: Any, day: Date, calendar: Calendar, into urls: inout [URL]) {
        if let object = json as? [String: Any] {
            if objectMatchesDay(object, day: day, calendar: calendar), let url = featureURL(in: object) {
                urls.append(url)
            }
            for value in object.values {
                if value is [String: Any] || value is [Any] {
                    collectFeatureURLs(from: value, day: day, calendar: calendar, into: &urls)
                }
            }
        } else if let array = json as? [Any] {
            for item in array {
                collectFeatureURLs(from: item, day: day, calendar: calendar, into: &urls)
            }
        }
    }

    private static func objectMatchesDay(_ object: [String: Any], day: Date, calendar: Calendar) -> Bool {
        let longDate = longDateText(day, calendar: calendar)
        let isoDate = isoDateText(day, calendar: calendar)
        if let published = object["datePublished"] as? String {
            let normalized = published.replacingOccurrences(of: "\u{00a0}", with: " ")
            if normalized.contains(longDate) || normalized.contains(isoDate) {
                return true
            }
        }
        if let name = object["name"] as? String, name.contains(longDate) {
            return true
        }
        return false
    }

    static func jsonLDHits(html: String) -> [JSONLDHit] {
        var hits: [JSONLDHit] = []
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            collectHits(from: json, into: &hits)
            if hits.count >= 12 { break }
        }
        return hits
    }

    private static func collectHits(from json: Any, into hits: inout [JSONLDHit]) {
        if hits.count >= 12 { return }
        if let object = json as? [String: Any] {
            let published = object["datePublished"] as? String
            let image = featureURL(in: object)
            if published != nil || image != nil {
                let rawDate = published ?? (object["name"] as? String) ?? ""
                hits.append(JSONLDHit(rawDate: rawDate, imageURL: image))
            }
            for value in object.values {
                if value is [String: Any] || value is [Any] {
                    collectHits(from: value, into: &hits)
                }
            }
        } else if let array = json as? [Any] {
            for item in array {
                collectHits(from: item, into: &hits)
            }
        }
    }

    private static func dayFromPath(_ text: String, calendar: Calendar) -> Date? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let pieces = components.path.split(separator: "/").map(String.init)
        guard pieces.count >= 3 else { return nil }
        for index in 0...(pieces.count - 3) {
            guard let year = Int(pieces[index]), (1985...2100).contains(year),
                  let month = Int(pieces[index + 1]), (1...12).contains(month),
                  let dayNumber = Int(pieces[index + 2]), (1...31).contains(dayNumber) else {
                continue
            }
            var parts = DateComponents()
            parts.year = year
            parts.month = month
            parts.day = dayNumber
            if let date = calendar.date(from: parts) {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }

    private static func isoDay(in text: String, calendar: Calendar) -> Date? {
        let characters = Array(text)
        guard characters.count >= 10 else { return nil }
        for index in 0...(characters.count - 10) {
            guard characters[index + 4] == "-", characters[index + 7] == "-" else { continue }
            let yearText = String(characters[index..<(index + 4)])
            let monthText = String(characters[(index + 5)..<(index + 7)])
            let dayText = String(characters[(index + 8)..<(index + 10)])
            guard let year = Int(yearText), (1985...2100).contains(year),
                  let month = Int(monthText), (1...12).contains(month),
                  let dayNumber = Int(dayText), (1...31).contains(dayNumber) else {
                continue
            }
            var parts = DateComponents()
            parts.year = year
            parts.month = month
            parts.day = dayNumber
            if let date = calendar.date(from: parts) {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }

    private static func longDay(in text: String, calendar: Calendar) -> Date? {
        let months = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
        for (index, name) in months.enumerated() {
            guard let range = text.range(of: name) else { continue }
            var rest = text[range.upperBound...]
            rest = rest.drop(while: { $0 == " " || $0 == "\u{00a0}" })
            var dayDigits = ""
            for character in rest {
                if character.isNumber { dayDigits.append(character) } else { break }
            }
            guard let dayNumber = Int(dayDigits), (1...31).contains(dayNumber) else { continue }
            var after = rest.dropFirst(dayDigits.count)
            after = after.drop(while: { $0 == " " || $0 == "," || $0 == "\u{00a0}" })
            var yearDigits = ""
            for character in after {
                if character.isNumber { yearDigits.append(character) } else { break }
            }
            guard yearDigits.count == 4, let year = Int(yearDigits) else { continue }
            var parts = DateComponents()
            parts.year = year
            parts.month = index + 1
            parts.day = dayNumber
            if let date = calendar.date(from: parts) {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }

    private static func featureURL(in object: [String: Any]) -> URL? {
        for key in ["contentUrl", "url", "image"] {
            if let string = object[key] as? String, let url = normalizeFeatureAsset(string) {
                return url
            }
        }
        return nil
    }

    private static func firstFeatureAsset(in html: String) -> URL? {
        let needle = "https://featureassets.gocomics.com/assets/"
        var search = html.startIndex
        while let range = html.range(of: needle, range: search..<html.endIndex) {
            var end = range.upperBound
            while end < html.endIndex {
                let character = html[end]
                if character == "\"" || character == "'" || character == "<" || character == " " || character == "\\" || character == ")" {
                    break
                }
                end = html.index(after: end)
            }
            let raw = String(html[range.lowerBound..<end])
            if let url = normalizeFeatureAsset(decodeHTMLEntities(raw)) {
                return url
            }
            search = range.upperBound
        }
        return nil
    }

    private static func decodeNumericEntities(_ string: String) -> String {
        var output = ""
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            if string[index] == "&", next < string.endIndex, string[next] == "#" {
                var cursor = string.index(after: next)
                var hex = false
                if cursor < string.endIndex, string[cursor] == "x" || string[cursor] == "X" {
                    hex = true
                    cursor = string.index(after: cursor)
                }
                let digitsStart = cursor
                while cursor < string.endIndex {
                    let character = string[cursor]
                    let isDigit = hex ? character.isHexDigit : (character >= "0" && character <= "9")
                    if !isDigit { break }
                    cursor = string.index(after: cursor)
                }
                if cursor > digitsStart,
                   cursor < string.endIndex,
                   string[cursor] == ";",
                   let code = UInt32(string[digitsStart..<cursor], radix: hex ? 16 : 10),
                   let scalar = Unicode.Scalar(code) {
                    output.append(Character(scalar))
                    index = string.index(after: cursor)
                    continue
                }
            }
            output.append(string[index])
            index = string.index(after: index)
        }
        return output
    }
}
