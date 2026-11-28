import Foundation

/// The network rules of an Adblock-syntax list (EasyList, uBlock Origin's
/// lists) that `BlockList` doesn't keep: rules on a path or a pattern, rules
/// for some request types, rules for some sites. Each becomes one WebKit
/// content-blocker rule.
///
/// WebKit refuses a whole rule list when one rule is invalid, so this only
/// writes what it can translate exactly and skips the rest:
/// - regex rules (`/…/`), and patterns with characters WebKit's regex subset
///   can't take (`|` inside, `{`, `}`, `\`, quotes, non-ASCII);
/// - options it can't honour: `redirect`, `removeparam`, `csp`, `header`,
///   `popup`, `document` blocks, cosmetic exceptions and the like;
/// - `domain=` mixing included and excluded sites (WebKit takes one or the
///   other per rule), and site entries with wildcards (`google.*`);
/// - patterns with fewer than four literal characters, which would catch far
///   more than they mean to.
///
/// Whole-domain rules (`||ads.example^`) stay with `BlockList`, which also
/// counts what a page loaded; these come on top of them.
enum NetworkFilters {
    /// One converted rule: the trigger as JSON, and whether it blocks or undoes.
    struct Rule: Sendable {
        let trigger: String
        let exception: Bool

        var json: String {
            #"{"trigger":\#(trigger),"action":{"type":"\#(exception ? "ignore-previous-rules" : "block")"}}"#
        }
    }

    /// Bump when the conversion changes, so compiled lists are made again.
    static let version = 2

    /// Rules of our own, on top of the lists, for the Ads switch.
    ///
    /// Popunder and overlay ad networks load their script from throwaway
    /// domains that change every few days, faster than any domain list:
    /// `https://ns.random-words.com/r6fisEJrR5zLry/142161`. uBlock Origin's
    /// Quick fixes list matches that shape with a regex, but only on a few
    /// sites; here it applies everywhere, as a third-party script only, in
    /// WebKit's regex subset (no `{n,m}`, so the counts are spelled out).
    static let builtInAds: [Rule] = [
        Rule(
            trigger: #"{"url-filter":"^https?://([a-z][a-z]*\\.)?[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]*\\.[a-z][a-z][a-z][a-z]*/[a-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z][0-9A-Za-z]*/[0-9][0-9][0-9][0-9][0-9]?[0-9]?$","url-filter-is-case-sensitive":true,"resource-type":["script"],"load-type":["third-party"]}"#,
            exception: false
        ),
    ]

    /// What WebKit blocks when a rule names no type: never pages themselves
    /// or popups, so a tapped link always opens.
    static let defaultTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping"]

    static func rules(in text: String) -> [Rule] {
        var rules: [Rule] = []
        text.enumerateLines { raw, _ in
            if let rule = convert(raw.trimmingCharacters(in: .whitespaces)) { rules.append(rule) }
        }
        return rules
    }

    static func convert(_ line: String) -> Rule? {
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["),
              // Cosmetic and scriptlet rules.
              !line.contains("##"), !line.contains("#@#"), !line.contains("#?#"),
              !line.contains("#$#"), !line.contains("#%#"), !line.contains("#+js")
        else { return nil }

        var rest = Substring(line)
        let exception = rest.hasPrefix("@@")
        if exception { rest = rest.dropFirst(2) }

        // Options after the last `$` (a `$` inside a pattern is rare and
        // would be in a regex rule, which is skipped anyway).
        var pattern = rest
        var options: [Substring] = []
        if let dollar = rest.lastIndex(of: "$") {
            pattern = rest[..<dollar]
            options = rest[rest.index(after: dollar)...].split(separator: ",").map {
                Substring($0.trimmingCharacters(in: .whitespaces))
            }
        }
        // Regex rules.
        if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") { return nil }

        // Whole-domain rules without options are BlockList's.
        if options.isEmpty, isWholeDomain(pattern) { return nil }

        guard let filter = urlFilter(from: pattern) else { return nil }
        guard let parsed = Options(options, exception: exception) else { return nil }
        // A whole-domain rule with nothing but a load type is BlockList's too.
        if isWholeDomain(pattern), parsed.onlyLoadType { return nil }

        var trigger = #"{"url-filter":"\#(json(filter))""#
        if parsed.caseSensitive { trigger += #","url-filter-is-case-sensitive":true"# }
        let types = parsed.types ?? (exception ? nil : defaultTypes)
        if let types {
            trigger += #","resource-type":["# + types.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        }
        if parsed.childFramesOnly { trigger += #","load-context":["child-frame"]"# }
        if let loadType = parsed.loadType { trigger += #","load-type":["\#(loadType)"]"# }
        if !parsed.ifDomains.isEmpty {
            trigger += #","if-domain":"# + quoted(parsed.ifDomains)
        } else if !parsed.unlessDomains.isEmpty {
            trigger += #","unless-domain":"# + quoted(parsed.unlessDomains)
        }
        trigger += "}"
        return Rule(trigger: trigger, exception: exception)
    }

    /// `||example.com^` with nothing after the separator.
    private static func isWholeDomain(_ pattern: Substring) -> Bool {
        guard pattern.hasPrefix("||"), pattern.hasSuffix("^") else { return false }
        let name = pattern.dropFirst(2).dropLast()
        return !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    // MARK: - Pattern

    /// Characters that pass as they are.
    private static func isPlain(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        if c.isLetter || c.isNumber { return true }
        return "-_/:=&%,;~!@#'<>".contains(c)
    }

    /// Characters that pass escaped.
    private static let escaped: Set<Character> = [".", "+", "?", "(", ")", "[", "]", "$"]

    /// The Adblock pattern as a WebKit `url-filter`, or nil when it can't be one.
    static func urlFilter(from raw: Substring) -> String? {
        var pattern = raw
        var out = ""
        var literal = 0

        if pattern.hasPrefix("||") {
            // Any subdomain of the host that follows.
            out = #"^[^:]+://+([^:/]+\.)?"#
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            out = "^"
            pattern = pattern.dropFirst()
        }
        var anchoredEnd = false
        if pattern.hasSuffix("|") {
            anchoredEnd = true
            pattern = pattern.dropLast()
        }
        // Wildcards at the ends add nothing to a search.
        while pattern.hasPrefix("*") { pattern = pattern.dropFirst(); if out == "^" { out = "" } }
        while pattern.hasSuffix("*") { pattern = pattern.dropLast(); anchoredEnd = false }
        guard !pattern.isEmpty else { return nil }

        let characters = Array(pattern)
        for (index, c) in characters.enumerated() {
            if c == "*" {
                out += ".*"
            } else if c == "^" {
                // A separator: anything but a letter, a digit or `_ - . %`,
                // or the end of the address.
                if index == characters.count - 1 {
                    out += #"([^a-zA-Z0-9_.%-].*)?$"#
                    anchoredEnd = false
                } else {
                    out += "[^a-zA-Z0-9_.%-]"
                }
            } else if escaped.contains(c) {
                out += "\\" + String(c)
                literal += 1
            } else if isPlain(c) {
                out.append(c)
                literal += 1
            } else {
                return nil
            }
        }
        guard literal >= 4 else { return nil }
        if anchoredEnd { out += "$" }
        return out
    }

    // MARK: - Options

    private struct Options {
        var types: [String]?
        var childFramesOnly = false
        var loadType: String?
        var ifDomains: [String] = []
        var unlessDomains: [String] = []
        var caseSensitive = false
        /// Nothing beyond `third-party` / `first-party` (or no option at all).
        var onlyLoadType = false

        private static let typeMap: [Substring: String] = [
            "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
            "font": "font", "media": "media", "xmlhttprequest": "raw", "xhr": "raw",
            "websocket": "raw", "other": "raw", "object": "raw", "ping": "ping", "beacon": "ping",
        ]
        private static let frameTypes: Set<Substring> = ["subdocument", "frame"]
        private static let ignored: Set<Substring> = ["important", "all", "~important"]

        init?(_ options: [Substring], exception: Bool) {
            var included = Set<String>()
            var excluded = Set<String>()
            var frames = false
            var sawOther = false
            for option in options where !option.isEmpty {
                let lower = Substring(option.lowercased())
                if Self.ignored.contains(lower) { continue }
                if lower == "third-party" || lower == "3p" || lower == "~first-party" || lower == "~1p" {
                    loadType = "third-party"
                } else if lower == "first-party" || lower == "1p" || lower == "~third-party" || lower == "~3p" {
                    loadType = "first-party"
                } else if lower == "match-case" {
                    caseSensitive = true
                    sawOther = true
                } else if lower.hasPrefix("domain=") || lower.hasPrefix("from=") {
                    sawOther = true
                    let value = lower.drop { $0 != "=" }.dropFirst()
                    for entry in value.split(separator: "|") {
                        let negated = entry.hasPrefix("~")
                        let name = negated ? entry.dropFirst() : entry
                        guard !name.isEmpty,
                              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
                              name.contains(".")
                        else {
                            // A wildcard entry: leaving it out of an include
                            // list blocks less; out of an exclude list, more.
                            if negated { return nil }
                            continue
                        }
                        if negated { unlessDomains.append("*" + name) } else { ifDomains.append("*" + name) }
                    }
                    if !ifDomains.isEmpty && !unlessDomains.isEmpty { return nil }
                    if ifDomains.isEmpty && unlessDomains.isEmpty { return nil }
                } else if let type = Self.typeMap[lower] {
                    included.insert(type)
                    sawOther = true
                } else if Self.frameTypes.contains(lower) {
                    frames = true
                    sawOther = true
                } else if lower.hasPrefix("~"), let type = Self.typeMap[lower.dropFirst()] {
                    excluded.insert(type)
                    sawOther = true
                } else {
                    // redirect, removeparam, csp, popup, document, elemhide,
                    // badfilter, denyallow, header, method, to=, …
                    return nil
                }
            }
            onlyLoadType = !sawOther
            if frames {
                // Frames only, and only frames: mixed with other types they
                // would need two rules.
                guard included.isEmpty, excluded.isEmpty else { return nil }
                types = ["document"]
                childFramesOnly = true
            } else if !included.isEmpty {
                types = Array(included).sorted()
            } else if !excluded.isEmpty {
                types = NetworkFilters.defaultTypes.filter { !excluded.contains($0) }
                if types?.isEmpty == true { return nil }
            }
            _ = exception
        }
    }

    // MARK: - JSON

    /// A regex as a JSON string body: backslashes doubled.
    private static func json(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
    }

    private static func quoted(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}
