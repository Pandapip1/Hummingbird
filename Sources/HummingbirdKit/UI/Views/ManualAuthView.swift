import Foundation
#if !canImport(WebKit)
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

/// Stand-in for the in-app login web view on platforms without a web view we can drive.
/// The person signs in using their own browser, then pastes the `Cookie` request header (and any other headers the
/// plugin needs) from the browser's developer tools. They are stored exactly as a web-view login would store them.
@MainActor
struct WebAuthSheet: View {
    let spec: WebAuthSpec
    let onFinish: (SourceAuth?) -> Void
    @State private var cookieText = ""
    @State private var headerText = ""

    private var host: String? { spec.startURL?.host }

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Sign in with your browser") {
                    if let url = spec.startURL { Link(url.absoluteString, destination: url.absoluteString) }
                    Text("Open the page above, sign in, then copy the values below from the browser's developer tools (Network tab, any request to the site).")
                }
                Section("2. Cookie header") {
                    TextField("name=value; name2=value2", text: $cookieText)
                }
                if !spec.headersToFind.isEmpty || !spec.domainHeadersToFind.isEmpty {
                    Section("3. Headers the plugin needs (one per line, Name: value)") {
                        TextEditor(text: $headerText)
                    }
                }
                Section {
                    Button("Save") { onFinish(buildAuth()) }
                    Button("Cancel") { onFinish(nil) }
                }
            }
            .navigationTitle(spec.title)
        }
    }

    func buildAuth() -> SourceAuth? {
        ManualAuth.build(cookieHeader: cookieText, headerLines: headerText, host: host, userAgent: spec.userAgent)
    }
}

/// Parsing for pasted credentials. Separate from the view so it can be tested.
enum ManualAuth {
    static func build(cookieHeader: String, headerLines: String, host: String?, userAgent: String?) -> SourceAuth? {
        guard let host, !host.isEmpty else { return nil }
        var auth = SourceAuth(userAgent: userAgent)
        let domain = "." + host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        for pair in cookieHeader.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { auth.cookieMap[domain, default: [:]][parts[0]] = parts[1] }
        }
        for line in headerLines.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { auth.headers[host, default: [:]][parts[0].lowercased()] = parts[1] }
        }
        return auth.isEmpty ? nil : auth
    }
}
#endif
