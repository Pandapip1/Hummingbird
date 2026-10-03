import Foundation
import SwiftSoup
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - DOM package

/// The DOM the plugin's `domParser` package exposes. Nodes live here and the script only holds integer handles
/// (see `DOMNode` in prelude.js). Only element nodes are exposed, as in the documented plugin DOM.
final class DOMStore {
    private var nodes: [Int: Element] = [:]
    private var next = 1

    private func put(_ e: Element) -> Int {
        let id = next
        next += 1
        nodes[id] = e
        return id
    }
    private func ref(_ e: Element?) -> Any { e.map { ["__node": put($0)] } ?? NSNull() }
    private func refs(_ list: [Element]) -> Any { list.map { ["__node": put($0)] } }
    private func refs(_ list: Elements?) -> Any { refs(list?.array() ?? []) }

    func parse(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        return String(put(doc))
    }

    func release(_ handle: Int) { nodes[handle] = nil }
    func removeAll() { nodes.removeAll() }

    /// JSON text of a property of the node.
    func get(handle: Int, property: String) -> String {
        guard let e = nodes[handle] else { return "null" }
        let value: Any
        switch property {
        case "nodeType": value = e.tagName().lowercased()
        case "tagName": value = e.tagName().uppercased()
        case "childNodes": value = refs(e.children())
        case "firstChild": value = ref(e.children().first())
        case "lastChild": value = ref(e.children().last())
        case "parentNode", "parentElement": value = ref(e.parent())
        case "attributes":
            var out: [String: String] = [:]
            if let attrs = e.getAttributes() { for a in attrs { out[a.getKey()] = a.getValue() } }
            value = out
        case "innerHTML": value = (try? e.html()) ?? ""
        case "outerHTML": value = (try? e.outerHtml()) ?? ""
        case "textContent": value = (try? e.text()) ?? ""
        case "text":
            let t = (try? e.text()) ?? ""
            value = t.isEmpty ? e.ownText() : t
        case "data": value = e.data()
        case "classList": value = Array((try? e.classNames()) ?? [])
        case "className": value = (try? e.className()) ?? ""
        default: value = NSNull()
        }
        return json(value)
    }

    /// `argsJSON` is `[method, ...args]`. Returns JSON text.
    func call(handle: Int, argsJSON: String) -> String {
        guard let e = nodes[handle],
              let data = argsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let method = args.first as? String else { return "null" }
        let arg = (args.count > 1 ? args[1] as? String : nil) ?? ""
        let value: Any
        switch method {
        case "getAttribute": value = (try? e.attr(arg)) ?? ""
        case "getElementById": value = ref((try? e.getElementById(arg)).flatMap { $0 })
        case "getElementsByClassName": value = refs(try? e.getElementsByClass(arg))
        case "getElementsByTagName": value = refs(try? e.getElementsByTag(arg))
        case "getElementsByName": value = refs(try? e.getElementsByAttributeValue("name", arg))
        case "querySelector": value = ref((try? e.select(arg))?.first())
        case "querySelectorAll": value = refs(try? e.select(arg))
        default: value = NSNull()
        }
        return json(value)
    }

    private func json(_ value: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Utilities package

/// Hash and encoding helpers. Inputs arrive as `{"s": "<utf8 text>"}` or `{"b": [bytes]}`.
/// Assumption: `md5`/`sha256` return byte arrays and the `...String` variants return lowercase hex.
enum UtilityPackage {
    static func call(_ name: String, _ a: String) -> String {
        switch name {
        case "toBase64": return Data(bytes(a)).base64EncodedString()
        case "fromBase64": return intArray(Array(Data(base64Encoded: a) ?? Data()))
        case "md5": return intArray(Array(Insecure.MD5.hash(data: Data(bytes(a)))))
        case "md5String": return hex(Insecure.MD5.hash(data: Data(a.utf8)))
        case "sha256": return intArray(Array(SHA256.hash(data: Data(bytes(a)))))
        case "sha256String": return hex(SHA256.hash(data: Data(a.utf8)))
        case "randomUUID": return UUID().uuidString.lowercased()
        default: return ""
        }
    }

    private static func bytes(_ json: String) -> [UInt8] {
        guard let d = json.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        if let s = o["s"] as? String { return Array(s.utf8) }
        if let b = o["b"] as? [Any] { return b.map { UInt8(truncatingIfNeeded: ($0 as? NSNumber)?.intValue ?? 0) } }
        return []
    }
    private static func intArray(_ b: [UInt8]) -> String { "[" + b.map { String($0) }.joined(separator: ",") + "]" }
    private static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 {
        d.map { String(format: "%02x", $0) }.joined()
    }
}
