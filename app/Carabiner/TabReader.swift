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

    /// TCC identifies Automation targets by bundle id, not name.
    var bundleId: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .brave:  return "com.brave.Browser"
        case .edge:   return "com.microsoft.edgemac"
        case .arc:    return "company.thebrowser.Browser"
        }
    }
}

/// What `resolve()` came back with. Denied Automation is called out separately because
/// it is the likeliest first-run stumble, and "no link anywhere" is the wrong thing to
/// tell someone who just clicked *Don't Allow*.
enum TabResolution: Equatable {
    case url(String)
    case notAuthorized
    case nothing
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

    /// Convenience wiring the real sources. A refused Apple Event only surfaces when
    /// nothing else produced a URL — a link on the clipboard is still perfectly grabbable.
    /// The browser is still only asked when it has to be: `tabURL` stays lazy.
    func resolve(argument: String? = nil) -> TabResolution {
        var refused = false
        let url = resolveURL(argument: argument,
                             tabURL: {
                                 let tab = frontTabURL(for: browser)
                                 refused = tab.notAuthorized
                                 return tab.url
                             },
                             clipboard: { NSPasteboard.general.string(forType: .string) })
        if let url { return .url(url) }
        return refused ? .notAuthorized : .nothing
    }
}

/// `errAEEventNotPermitted` — the user denied (or has not granted) Automation access
/// for this browser. Indistinguishable from "no tab" unless we read the error out.
private let errAEEventNotPermitted = -1743

func frontTabURL(for browser: Browser) -> (url: String?, notAuthorized: Bool) {
    let script: String
    if browser == .safari {
        script = "tell application \"\(browser.appName)\" to get URL of front document"
    } else {
        script = "tell application \"\(browser.appName)\" to get URL of active tab of front window"
    }
    guard let apple = NSAppleScript(source: script) else {
        NSLog("Carabiner: couldn't compile the front-tab AppleScript for %@", browser.appName)
        return (nil, false)
    }
    var err: NSDictionary?
    let out = apple.executeAndReturnError(&err)
    if let err {
        let code = (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = (err[NSAppleScript.errorMessage] as? String) ?? "no message"
        NSLog("Carabiner: front-tab AppleScript failed for %@ (error %d): %@",
              browser.appName, code, message)
        return (nil, code == errAEEventNotPermitted)
    }
    return (out.stringValue, false)
}
