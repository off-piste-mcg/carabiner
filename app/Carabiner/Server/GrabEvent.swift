import Foundation

/// One JSON object per line (NDJSON). Newline-delimited rather than SSE because the
/// client only needs "a sequence of objects" and `\n` framing is trivially correct on
/// both sides. JSONSerialization does the escaping — hand-built JSON would break the
/// framing the first time a filename contained a quote or an error message a newline.
enum GrabEvent {
    static func line(for event: ProgressEvent) -> String {
        switch event {
        case .probe:  return encode(["stage": "probe"])
        case .prompt: return encode(["stage": "prompt"])
        case .save:   return encode(["stage": "save"])
        case .download(let pct):
            var o: [String: Any] = ["stage": "download"]
            if let pct { o["pct"] = pct }
            return encode(o)
        case .item(let index, let total):
            return encode(["stage": "item", "index": index, "total": total])
        case .convert(let mode):
            return encode(["stage": "convert", "mode": mode.rawValue])
        }
    }

    static func line(forUser user: String) -> String { encode(["from": user]) }

    static func line(for result: GrabResult) -> String {
        let state = result.cancelled ? "cancelled" : (result.ok ? "ok" : "error")
        return encode(["result": state, "message": result.message])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return "{\"result\":\"error\",\"message\":\"encode failed\"}\n" }
        return json + "\n"
    }
}
