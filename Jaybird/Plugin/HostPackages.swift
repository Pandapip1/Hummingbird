import Foundation
import JavaScriptCore
import CryptoKit
import SwiftSoup

// MARK: - DOM parser package

@objc protocol DOMNodeExports: JSExport {
    var nodeType: String { get }
    var tagName: String { get }
    var childNodes: [DOMNode] { get }
    var firstChild: DOMNode? { get }
    var lastChild: DOMNode? { get }
    var parentNode: DOMNode? { get }
    var parentElement: DOMNode? { get }
    var attributes: [String: String] { get }
    var innerHTML: String { get }
    var outerHTML: String { get }
    var textContent: String { get }
    var text: String { get }
    var data: String { get }
    var classList: [String] { get }
    var className: String { get }
    func getAttribute(_ key: String) -> String
    func getElementById(_ id: String) -> DOMNode?
    func getElementsByClassName(_ name: String) -> [DOMNode]
    func getElementsByTagName(_ name: String) -> [DOMNode]
    func getElementsByName(_ name: String) -> [DOMNode]
    func querySelector(_ selector: String) -> DOMNode?
    func querySelectorAll(_ selector: String) -> [DOMNode]
    func dispose()
}

/// A DOM element backed by SwiftSoup. Only element nodes are exposed, as in the documented plugin DOM.
@objc final class DOMNode: NSObject, DOMNodeExports {
    private let element: Element
    init(_ element: Element) { self.element = element }

    var nodeType: String { element.tagName().lowercased() }
    var tagName: String { element.tagName().uppercased() }
    var childNodes: [DOMNode] { element.children().array().map(DOMNode.init) }
    var firstChild: DOMNode? { element.children().first().map(DOMNode.init) }
    var lastChild: DOMNode? { element.children().last().map(DOMNode.init) }
    var parentNode: DOMNode? { element.parent().map(DOMNode.init) }
    var parentElement: DOMNode? { parentNode }
    var attributes: [String: String] {
        var out: [String: String] = [:]
        if let attrs = element.getAttributes() { for a in attrs { out[a.getKey()] = a.getValue() } }
        return out
    }
    var innerHTML: String { (try? element.html()) ?? "" }
    var outerHTML: String { (try? element.outerHtml()) ?? "" }
    var textContent: String { (try? element.text()) ?? "" }
    var text: String { let t = textContent; return t.isEmpty ? element.ownText() : t }
    var data: String { element.data() }
    var classList: [String] { Array((try? element.classNames()) ?? []) }
    var className: String { (try? element.className()) ?? "" }

    func getAttribute(_ key: String) -> String { (try? element.attr(key)) ?? "" }
    func getElementById(_ id: String) -> DOMNode? { (try? element.getElementById(id)).flatMap { $0 }.map(DOMNode.init) }
    func getElementsByClassName(_ name: String) -> [DOMNode] { ((try? element.getElementsByClass(name)) ?? Elements()).array().map(DOMNode.init) }
    func getElementsByTagName(_ name: String) -> [DOMNode] { ((try? element.getElementsByTag(name)) ?? Elements()).array().map(DOMNode.init) }
    func getElementsByName(_ name: String) -> [DOMNode] { ((try? element.getElementsByAttributeValue("name", name)) ?? Elements()).array().map(DOMNode.init) }
    func querySelector(_ selector: String) -> DOMNode? { (try? element.select(selector))?.first().map(DOMNode.init) }
    func querySelectorAll(_ selector: String) -> [DOMNode] { ((try? element.select(selector)) ?? Elements()).array().map(DOMNode.init) }
    func dispose() {}
}

@objc protocol DOMParserExports: JSExport {
    func parseFromString(_ html: String, _ contentType: String) -> DOMNode?
}

@objc final class DOMParserPackage: NSObject, DOMParserExports {
    func parseFromString(_ html: String, _ contentType: String) -> DOMNode? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        return DOMNode(doc)
    }
}

// MARK: - Utilities package

@objc protocol UtilityExports: JSExport {
    func toBase64(_ input: JSValue) -> String
    func fromBase64(_ string: String) -> [Int]
    func md5(_ input: JSValue) -> [Int]
    func md5String(_ string: String) -> String
    func sha256(_ input: JSValue) -> [Int]
    func sha256String(_ string: String) -> String
    func randomUUID() -> String
}

/// Hash and encoding helpers. Byte-array parameters accept a JS string (UTF-8), an array of numbers or a typed array.
/// Assumption: `md5`/`sha256` return byte arrays and the `...String` variants return lowercase hex.
@objc final class UtilityPackage: NSObject, UtilityExports {
    private func bytes(_ v: JSValue) -> [UInt8] {
        if v.isString { return Array((v.toString() ?? "").utf8) }
        let ctx = v.context!
        let slice = ctx.evaluateScript("(function(v){return Array.prototype.slice.call(v);})")
        let arr = slice?.call(withArguments: [v])?.toArray() as? [NSNumber] ?? []
        return arr.map { UInt8(truncatingIfNeeded: $0.intValue) }
    }
    private func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    func toBase64(_ input: JSValue) -> String { Data(bytes(input)).base64EncodedString() }
    func fromBase64(_ string: String) -> [Int] { (Data(base64Encoded: string) ?? Data()).map { Int($0) } }
    func md5(_ input: JSValue) -> [Int] { Insecure.MD5.hash(data: Data(bytes(input))).map { Int($0) } }
    func md5String(_ string: String) -> String { hex(Insecure.MD5.hash(data: Data(string.utf8))) }
    func sha256(_ input: JSValue) -> [Int] { SHA256.hash(data: Data(bytes(input))).map { Int($0) } }
    func sha256String(_ string: String) -> String { hex(SHA256.hash(data: Data(string.utf8))) }
    func randomUUID() -> String { UUID().uuidString.lowercased() }
}
