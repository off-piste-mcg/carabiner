import SafariServices

/// Required by Safari even when unused: our extension talks to the app over the loopback
/// socket like Chrome's does, so there is no native messaging to handle here. Keeping the
/// transport identical across browsers is the point — one code path, one failure mode.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
