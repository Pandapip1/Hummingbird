import Foundation

/// Reads what was typed into the search-or-address field as a link when it
/// looks like one, otherwise as a search. Links only ever go to the sources
/// that recognise them; Hummingbird doesn't open arbitrary web pages.
enum AddressInput {
    /// The URL `text` addresses, or `nil` when it is a search.
    ///
    /// An address is either a URL with a scheme (`https://…`, or any scheme a
    /// source may recognise), or a host with an optional port, path, query
    /// and fragment, which is read as `https://`. A host is a domain name with
    /// a dot and a top-level label of letters (`example.com`), `localhost`, or
    /// an IPv4 or bracketed IPv6 address. Anything containing whitespace is a
    /// search, as is a host-like word that names a user (`me@example.com`).
    static func url(from text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }

        if let separator = input.range(of: "://") {
            let scheme = input[..<separator.lowerBound]
            guard isScheme(scheme), let url = URL(string: input) else { return nil }
            // A web address must name a host; other schemes are left to sources.
            if isWebScheme(url.scheme), url.host(percentEncoded: false).map(isHost) != true { return nil }
            return url
        }

        guard let url = URL(string: "https://" + input), url.user == nil,
              let host = url.host(percentEncoded: false), isHost(host) else { return nil }
        return url
    }

    /// Whether `text` names its scheme (`https://…`), so it is certainly
    /// meant as a link. Scheme-less input that merely looks like a host
    /// ("node.js", "README.md") may just as well be a search.
    static func hasExplicitScheme(_ text: String) -> Bool {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = input.range(of: "://") else { return false }
        return isScheme(input[..<separator.lowerBound])
    }

    private static func isWebScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func isScheme(_ scheme: Substring) -> Bool {
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    private static func isHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" { return true }
        // IPv6: Foundation reports it without the brackets.
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        guard labels.count >= 2, labels.allSatisfy(isLabel), let topLevel = labels.last else { return false }
        // A top-level domain is letters (or an internationalised xn-- label),
        // which keeps numbers and versions such as "3.14" or "v1.2" searches.
        return topLevel.count >= 2
            && (topLevel.allSatisfy(\.isLetter) || topLevel.hasPrefix("xn--"))
    }

    private static func isLabel(_ label: Substring) -> Bool {
        (1...63).contains(label.count) && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
