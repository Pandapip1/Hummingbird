import Foundation

/// Errors raised by plugin code or the host while running it. Mirrors the `plugin_type` strings plugins throw.
enum PluginError: LocalizedError {
    case loginRequired(String)
    case captchaRequired(url: String?, body: String?)
    case unavailable(String)
    case ageRestricted(String)
    case timeout(String)
    case critical(String)
    case implementation(String)
    case reloadRequired(message: String, reloadData: String?)
    case execution(String)
    case compilation(String)
    case notInstalled
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired(let m): return m.isEmpty ? "Login required" : m
        case .captchaRequired: return "A captcha must be completed to continue"
        case .unavailable(let m): return m.isEmpty ? "This content is unavailable" : m
        case .ageRestricted(let m): return m.isEmpty ? "This content is age restricted" : m
        case .timeout(let m): return m.isEmpty ? "The plugin timed out" : m
        case .critical(let m), .implementation(let m), .execution(let m), .compilation(let m), .notSupported(let m): return m
        case .reloadRequired(let m, _): return m
        case .notInstalled: return "No plugin handles this"
        }
    }

    struct Payload: Decodable {
        var type: String?
        var msg: String?
        var url: String?
        var body: String?
        var reloadData: String?
    }

    init(payload p: Payload) {
        let m = p.msg ?? ""
        switch p.type ?? "" {
        case "ScriptLoginRequiredException": self = .loginRequired(m)
        case "CaptchaRequiredException": self = .captchaRequired(url: p.url, body: p.body)
        case "UnavailableException": self = .unavailable(m)
        case "AgeException": self = .ageRestricted(m)
        case "ScriptTimeoutException": self = .timeout(m)
        case "CriticalException": self = .critical(m)
        case "ScriptImplementationException": self = .implementation(m)
        case "ReloadRequiredException": self = .reloadRequired(message: m, reloadData: p.reloadData)
        case "ScriptCompilationException": self = .compilation(m)
        default: self = .execution(m)
        }
    }
}
