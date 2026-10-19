import Foundation

/// Talks to the small Apps Script web app attached to the team Google Sheet.
enum SheetService {

    struct Response: Decodable {
        let ok: Bool
        let row: Int?
        let error: String?
        let sheet: String?
        let columns: [String: String]?
        let updated: Bool?
    }

    enum SheetError: LocalizedError {
        case notConfigured, badURL, server(String), badReply(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Sheet link isn't set. Open Settings → Google Sheet."
            case .badURL: return "The Web App URL doesn't look right. It should end with /exec."
            case .server(let m): return m
            case .badReply(let m): return "Unexpected reply from Google: \(m)"
            }
        }
    }

    private static func post(_ body: [String: Any]) async throws -> Response {
        let urlString = Pref.string(Pref.webAppURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { throw SheetError.notConfigured }
        guard let url = URL(string: urlString), url.scheme == "https" else { throw SheetError.badURL }

        var payload = body
        payload["token"] = Pref.string(Pref.token)

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        // text/plain avoids a CORS preflight; Apps Script reads e.postData.contents.
        req.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // Apps Script answers POST with a 302 to googleusercontent.com, which
        // URLSession follows as a GET and returns the JSON.
        let (data, _) = try await URLSession.shared.data(for: req)
        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            if !r.ok { throw SheetError.server(r.error ?? "Unknown error from the sheet script.") }
            return r
        } catch let e as SheetError {
            throw e
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("<html") || text.contains("<!DOCTYPE") {
                throw SheetError.badReply("Google returned a web page instead of data. Re-deploy the script with “Who has access: Anyone”, and paste the /exec URL.")
            }
            throw SheetError.badReply(String(text.prefix(200)))
        }
    }

    /// Checks the connection and returns which columns the script detected.
    static func ping() async throws -> Response {
        try await post(["action": "ping"])
    }

    /// Writes one row. Returns the row number it landed on.
    static func log(_ p: PendingLog) async throws -> Response {
        var body: [String: Any] = [
            "action": "log",
            "task": p.task,
            "client": p.client,
            "member": p.member,
            "status": p.status,
            "date": p.date,
            "time": Fmt.sheetTime(p.seconds),
            "minutes": Int((Fmt.rounded(p.seconds) / 60).rounded()),
            "folder": p.folder,
        ]
        if let r = p.updateRow { body["updateRow"] = r }
        return try await post(body)
    }
}
