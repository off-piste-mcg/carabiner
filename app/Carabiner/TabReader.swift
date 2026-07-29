import AppKit

enum Browser: String, CaseIterable {
    case chrome, safari, brave, edge, arc
    var appName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        case .brave:  return "Brave Browser"
        case .edge:   return "Microsoft Edge"
        case .arc:    return "Arc"
        }
    }
}

struct TabReader {
    var browser: Browser

    func isURL(_ s: String) -> Bool {
        guard let r = s.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) else { return false }
        return r.lowerBound == s.startIndex
    }

    /// Argument wins; else the browser tab; else the clipboard. Injectable for tests.
    func resolveURL(argument: String?,
                    tabURL: () -> String?,
                    clipboard: () -> String?) -> String? {
        if let a = argument, isURL(a) { return a }
        if let t = tabURL(), isURL(t) { return t }
        if let c = clipboard(), isURL(c) { return c }
        return nil
    }

    /// Convenience wiring the real sources.
    func resolve(argument: String? = nil) -> String? {
        resolveURL(argument: argument,
                   tabURL: { frontTabURL(for: browser) },
                   clipboard: { NSPasteboard.general.string(forType: .string) })
    }
}

func frontTabURL(for browser: Browser) -> String? {
    let script: String
    if browser == .safari {
        script = "tell application \"\(browser.appName)\" to get URL of front document"
    } else {
        script = "tell application \"\(browser.appName)\" to get URL of active tab of front window"
    }
    var err: NSDictionary?
    let out = NSAppleScript(source: script)?.executeAndReturnError(&err)
    return out?.stringValue
}
