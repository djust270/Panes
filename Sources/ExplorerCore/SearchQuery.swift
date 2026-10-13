import Foundation

/// What the user typed into the search box, parsed Windows-style: words that must all appear
/// in the name (or, with Spotlight, the contents), `*` and `?` wildcards, "quoted phrases", and
/// the filters `kind:`, `date:` (or `datemodified:`), `size:` and `ext:`.
///
///     report kind:document date:"last week" size:>1MB ext:pdf
///
/// Unknown `key:value` words are searched for as-is.
public struct SearchQuery: Sendable, Hashable {
    /// Lowercased search words; those containing `*` or `?` match the whole name as a pattern.
    public var terms: [String] = []
    public var kinds: Set<FileKind> = []
    /// Extensions without the dot, lowercased.
    public var extensions: Set<String> = []
    public var date: DateFilter?
    public var size: SizeFilter?

    public init(terms: [String] = [], kinds: Set<FileKind> = [], extensions: Set<String> = [],
                date: DateFilter? = nil, size: SizeFilter? = nil) {
        self.terms = terms
        self.kinds = kinds
        self.extensions = extensions
        self.date = date
        self.size = size
    }

    public init(parsing text: String, calendar: Calendar = .current) {
        var tokens = Self.tokenize(text)[...]
        while let token = tokens.popFirst() {
            guard let (key, filterValue) = Self.filter(in: token) else {
                appendTerm(token.unquoted)
                continue
            }
            var value = filterValue
            // `date:last week` without quotes.
            if ["date", "datemodified", "modified"].contains(key),
               ["this", "last"].contains(value.lowercased()),
               let next = tokens.first, ["week", "month", "year"].contains(next.unquoted.lowercased()) {
                value += " " + next.unquoted
                tokens.removeFirst()
            }
            if !apply(key: key, value: value, calendar: calendar) {
                appendTerm(token.unquoted)
            }
        }
    }

    /// Nothing to search for.
    public var isEmpty: Bool {
        terms.isEmpty && kinds.isEmpty && extensions.isEmpty && date == nil && size == nil
    }

    private mutating func appendTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains(where: { $0 != "*" }) else { return }
        terms.append(trimmed.lowercased())
    }

    private mutating func apply(key: String, value: String, calendar: Calendar) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces)
        switch key {
        case "kind":
            guard let kind = Self.kindNames[value.lowercased()] else { return false }
            kinds.insert(kind)
        case "ext":
            let ext = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".*"))
            guard !ext.isEmpty else { return false }
            extensions.insert(ext)
        case "date", "datemodified", "modified":
            guard let filter = DateFilter(parsing: value, calendar: calendar) else { return false }
            date = filter
        case "size":
            guard let filter = SizeFilter(parsing: value) else { return false }
            size = filter
        default:
            return false
        }
        return true
    }

    private static let kindNames: [String: FileKind] = {
        var names: [String: FileKind] = [:]
        let table: [(FileKind, [String])] = [
            (.folders, ["folder", "folders", "directory"]),
            (.documents, ["document", "documents", "doc", "docs"]),
            (.pictures, ["picture", "pictures", "image", "images", "photo", "photos", "pic", "pics"]),
            (.music, ["music", "audio", "song", "songs"]),
            (.videos, ["video", "videos", "movie", "movies"]),
            (.archives, ["compressed", "archive", "archives", "zip"]),
            (.applications, ["app", "apps", "application", "applications", "program", "programs"]),
        ]
        for (kind, words) in table {
            for word in words { names[word] = kind }
        }
        return names
    }()

    // MARK: Tokens

    /// A word of the query, with any quotes still in it.
    private struct Token {
        let raw: String

        var unquoted: String { raw.replacingOccurrences(of: "\"", with: "") }
    }

    /// Splits on whitespace outside quotes.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(Token(raw: current)) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(Token(raw: current)) }
        return tokens
    }

    /// `key:value` if the token starts with an unquoted word and a colon.
    private static func filter(in token: Token) -> (key: String, value: String)? {
        guard let colon = token.raw.firstIndex(of: ":") else { return nil }
        let key = token.raw[..<colon]
        guard !key.isEmpty, key.allSatisfy(\.isLetter) else { return nil }
        let value = token.raw[token.raw.index(after: colon)...].replacingOccurrences(of: "\"", with: "")
        guard !value.isEmpty else { return nil }
        return (key.lowercased(), value)
    }

    // MARK: Matching

    /// Whether `item` matches everything: name and filters. (Spotlight also matches words in
    /// the contents; see `matchesFilters` for its results.)
    public func matches(_ item: FileItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        matchesName(item.name) && matchesFilters(item, now: now, calendar: calendar)
    }

    /// Every term appears in `name`, or matches it as a pattern; case- and accent-insensitive.
    public func matchesName(_ name: String) -> Bool {
        let folded = Self.fold(name)
        return terms.allSatisfy { term in
            let term = Self.fold(term)
            return Self.isPattern(term) ? Self.glob(term, matches: folded) : folded.contains(term)
        }
    }

    /// Pattern terms only: the part of the name match Spotlight can't be trusted with.
    public func matchesNamePatterns(_ name: String) -> Bool {
        SearchQuery(terms: terms.filter(Self.isPattern)).matchesName(name)
    }

    public func matchesFilters(_ item: FileItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if !kinds.isEmpty, !kinds.contains(where: { $0.matches(item) }) { return false }
        if !extensions.isEmpty, item.isFolder || !extensions.contains(item.pathExtension) { return false }
        if let date {
            guard let modified = item.dateModified, date.contains(modified, now: now, calendar: calendar) else {
                return false
            }
        }
        if let size {
            guard !item.isFolder, let bytes = item.size, size.contains(bytes) else { return false }
        }
        return true
    }

    static func isPattern(_ term: String) -> Bool {
        term.contains("*") || term.contains("?")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// `*` matches any run of characters, `?` any one character; the whole name must match.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let pattern = Array(pattern)
        let text = Array(text)
        var patternIndex = 0
        var textIndex = 0
        var starIndex: Int?
        var starMatch = 0
        while textIndex < text.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "?" || pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starMatch = textIndex
                patternIndex += 1
            } else if let star = starIndex {
                patternIndex = star + 1
                starMatch += 1
                textIndex = starMatch
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }

    // MARK: Spotlight

    /// The query in Spotlight's query language (for `NSPredicate(fromMetadataQueryString:)`).
    /// Plain words match the name or a word in the contents; patterns, kinds and extensions
    /// are approximated and should be re-checked with `matchesNamePatterns` and `matchesFilters`.
    public func spotlightQuery(now: Date = Date(), calendar: Calendar = .current) -> String {
        var clauses: [String] = []
        for term in terms {
            if Self.isPattern(term) {
                let pattern = Self.escape(term, keepingWildcards: true).replacingOccurrences(of: "?", with: "*")
                clauses.append("kMDItemFSName == \"\(pattern)\"cd")
            } else {
                let word = Self.escape(term, keepingWildcards: false)
                clauses.append("(kMDItemFSName == \"*\(word)*\"cd || kMDItemTextContent == \"\(word)*\"cdw)")
            }
        }
        if !kinds.isEmpty {
            let types = kinds.sorted { $0.rawValue < $1.rawValue }.flatMap(\.contentTypeIdentifiers)
            clauses.append(Self.anyOf(types.map { "kMDItemContentTypeTree == \"\($0)\"" }))
        }
        if !extensions.isEmpty {
            let names = extensions.sorted().map { ext in
                "kMDItemFSName == \"*.\(Self.escape(ext, keepingWildcards: false))\"c"
            }
            clauses.append(Self.anyOf(names))
        }
        if let date {
            let (from, to) = date.interval(now: now, calendar: calendar)
            if let from { clauses.append("kMDItemFSContentChangeDate >= \(Self.spotlightTime(from))") }
            if let to { clauses.append("kMDItemFSContentChangeDate < \(Self.spotlightTime(to))") }
        }
        if let size {
            if let min = size.minimum { clauses.append("kMDItemFSSize >= \(min)") }
            if let max = size.maximum { clauses.append("kMDItemFSSize < \(max)") }
        }
        return clauses.joined(separator: " && ")
    }

    private static func anyOf(_ clauses: [String]) -> String {
        clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: " || ") + ")"
    }

    private static func escape(_ text: String, keepingWildcards: Bool) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\"", "\\": result += "\\\(character)"
            case "*" where !keepingWildcards: result += "\\*"
            default: result.append(character)
            }
        }
        return result
    }

    private static func spotlightTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "$time.iso(\(formatter.string(from: date)))"
    }
}

// MARK: - Date filter

/// `date:` — a named period ("today", "last week"…) or dates: `2024-05-01`, `>2024-05-01`,
/// `<=2024-05-01`, `2024-05-01..2024-05-31`. Matches the date modified.
public enum DateFilter: Sendable, Hashable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear
    /// From (inclusive) to (exclusive); either end may be open.
    case range(from: Date?, to: Date?)

    // swiftlint:disable:next cyclomatic_complexity
    public init?(parsing text: String, calendar: Calendar = .current) {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        let named: [String: DateFilter] = [
            "today": .today, "yesterday": .yesterday,
            "this week": .thisWeek, "thisweek": .thisWeek, "last week": .lastWeek, "lastweek": .lastWeek,
            "this month": .thisMonth, "thismonth": .thisMonth, "last month": .lastMonth, "lastmonth": .lastMonth,
            "this year": .thisYear, "thisyear": .thisYear, "last year": .lastYear, "lastyear": .lastYear,
        ]
        if let filter = named[text] {
            self = filter
            return
        }
        func day(_ text: Substring) -> Date? { Self.day(String(text), calendar: calendar) }
        func nextDay(_ date: Date) -> Date? { calendar.date(byAdding: .day, value: 1, to: date) }

        if let dots = text.range(of: "..") {
            guard let from = day(text[..<dots.lowerBound]), let to = day(text[dots.upperBound...]),
                  let end = nextDay(to) else { return nil }
            self = .range(from: from, to: end)
        } else if text.hasPrefix(">=") {
            guard let date = day(text.dropFirst(2)) else { return nil }
            self = .range(from: date, to: nil)
        } else if text.hasPrefix("<=") {
            guard let date = day(text.dropFirst(2)), let end = nextDay(date) else { return nil }
            self = .range(from: nil, to: end)
        } else if text.hasPrefix(">") {
            guard let date = day(text.dropFirst()), let start = nextDay(date) else { return nil }
            self = .range(from: start, to: nil)
        } else if text.hasPrefix("<") {
            guard let date = day(text.dropFirst()) else { return nil }
            self = .range(from: nil, to: date)
        } else {
            guard let date = day(text[...]), let end = nextDay(date) else { return nil }
            self = .range(from: date, to: end)
        }
    }

    /// Start of the day `text` names, in yyyy-MM-dd form.
    private static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-").map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// From (inclusive) and to (exclusive), relative to `now` for named periods.
    public func interval(now: Date, calendar: Calendar) -> (from: Date?, to: Date?) {
        func start(of component: Calendar.Component, offset: Int) -> Date? {
            guard let current = calendar.dateInterval(of: component, for: now)?.start else { return nil }
            return calendar.date(byAdding: component, value: offset, to: current)
        }
        func period(_ component: Calendar.Component, _ offset: Int) -> (Date?, Date?) {
            (start(of: component, offset: offset), start(of: component, offset: offset + 1))
        }
        switch self {
        case .today: return period(.day, 0)
        case .yesterday: return period(.day, -1)
        case .thisWeek: return period(.weekOfYear, 0)
        case .lastWeek: return period(.weekOfYear, -1)
        case .thisMonth: return period(.month, 0)
        case .lastMonth: return period(.month, -1)
        case .thisYear: return period(.year, 0)
        case .lastYear: return period(.year, -1)
        case let .range(from, to): return (from, to)
        }
    }

    public func contains(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        let (from, to) = interval(now: now, calendar: calendar)
        if let from, date < from { return false }
        if let to, date >= to { return false }
        return true
    }
}

// MARK: - Size filter

/// `size:` — Windows' size groups (empty, tiny, small, medium, large, huge, gigantic) or
/// sizes such as `>10MB`, `<=1.5GB`, `10MB..1GB` (1 KB = 1024 bytes). A bare size means at
/// least that size.
public struct SizeFilter: Sendable, Hashable {
    /// Inclusive.
    public var minimum: Int64?
    /// Exclusive.
    public var maximum: Int64?

    public init(minimum: Int64?, maximum: Int64?) {
        self.minimum = minimum
        self.maximum = maximum
    }

    // swiftlint:disable:next cyclomatic_complexity
    public init?(parsing text: String) {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        let kb: Int64 = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let named: [String: SizeFilter] = [
            "empty": SizeFilter(minimum: 0, maximum: 1),
            "tiny": SizeFilter(minimum: 1, maximum: 16 * kb),
            "small": SizeFilter(minimum: 16 * kb, maximum: mb),
            "medium": SizeFilter(minimum: mb, maximum: 128 * mb),
            "large": SizeFilter(minimum: 128 * mb, maximum: gb),
            "huge": SizeFilter(minimum: gb, maximum: 4 * gb),
            "gigantic": SizeFilter(minimum: 4 * gb, maximum: nil),
        ]
        if let filter = named[text] {
            self = filter
        } else if let dots = text.range(of: "..") {
            guard let low = Self.bytes(text[..<dots.lowerBound]), let high = Self.bytes(text[dots.upperBound...])
            else { return nil }
            self.init(minimum: low, maximum: high + 1)
        } else if text.hasPrefix(">=") {
            guard let bytes = Self.bytes(text.dropFirst(2)) else { return nil }
            self.init(minimum: bytes, maximum: nil)
        } else if text.hasPrefix("<=") {
            guard let bytes = Self.bytes(text.dropFirst(2)) else { return nil }
            self.init(minimum: nil, maximum: bytes + 1)
        } else if text.hasPrefix(">") {
            guard let bytes = Self.bytes(text.dropFirst()) else { return nil }
            self.init(minimum: bytes + 1, maximum: nil)
        } else if text.hasPrefix("<") {
            guard let bytes = Self.bytes(text.dropFirst()) else { return nil }
            self.init(minimum: nil, maximum: bytes)
        } else {
            guard let bytes = Self.bytes(text[...]) else { return nil }
            self.init(minimum: bytes, maximum: nil)
        }
    }

    /// "10mb", "1.5 gb", "300" (bytes).
    private static func bytes(_ text: Substring) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let number = text.prefix { $0.isNumber || $0 == "." }
        let unit = text.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), value >= 0 else { return nil }
        let multipliers: [String: Double] = [
            "": 1, "b": 1, "k": 1024, "kb": 1024, "m": 1_048_576, "mb": 1_048_576,
            "g": 1_073_741_824, "gb": 1_073_741_824, "t": 1_099_511_627_776, "tb": 1_099_511_627_776,
        ]
        guard let multiplier = multipliers[unit] else { return nil }
        return Int64((value * multiplier).rounded())
    }

    public func contains(_ bytes: Int64) -> Bool {
        if let minimum, bytes < minimum { return false }
        if let maximum, bytes >= maximum { return false }
        return true
    }
}
