import Foundation
import SwiftUI

/// The team database (Supabase). The anon key is public by design: what each
/// person can read or change is enforced by the database rules in Supabase/schema.sql.
enum Cloud {
    static let url = "https://lxsjwiqhfotbowsgcexs.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4c2p3aXFoZm90Ym93c2djZXhzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0Mjg3NjgsImV4cCI6MjEwODAwNDc2OH0.LbgdJQ-7uk43qBVtL1FhTXB7n70Xe-D6see7cwDhRd0"

    struct CloudError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// Pulls a readable message out of an error reply from Supabase.
    static func message(from data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for k in ["error_description", "msg", "message", "error"] {
                if let s = obj[k] as? String, !s.isEmpty { return s }
            }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "Server error \(status)" : String(text.prefix(200))
    }

    // MARK: Dates

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// Parses Postgres timestamps ("2026-10-19T18:40:12.123456+00:00") and plain dates ("2026-10-19").
    static func date(_ any: Any?) -> Date? {
        guard var s = any as? String, !s.isEmpty else { return nil }
        if s.count == 10 { return Fmt.isoDay.date(from: s) }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Sign-in session

struct CloudSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var email: String
}

@MainActor
final class CloudAuth: ObservableObject {
    static let shared = CloudAuth()

    @Published private(set) var session: CloudSession?
    @Published var busy = false
    @Published var message: String?

    var signedIn: Bool { session != nil }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTimer Dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            session = try? dec.decode(CloudSession.self, from: data)
        }
    }

    private func save() {
        if let s = session {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(s) {
                try? data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: Actions

    func signIn(email: String, password: String) async {
        await run {
            let body: [String: Any] = ["email": email, "password": password]
            let obj = try await Self.authCall("token?grant_type=password", body)
            try self.adopt(obj)
            self.message = nil
        }
    }

    func signUp(email: String, password: String, name: String) async {
        await run {
            let body: [String: Any] = ["email": email, "password": password, "data": ["full_name": name]]
            let obj = try await Self.authCall("signup", body)
            if obj["access_token"] != nil {
                try self.adopt(obj)
                self.message = nil
            } else {
                self.message = "Account created. Check your email to confirm it, then sign in."
            }
        }
    }

    /// Changes the signed-in person's own password.
    func changePassword(_ newPassword: String) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let t = try await token()
            _ = try await Self.authCall("user", ["password": newPassword], method: "PUT", bearer: t)
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func signOut() {
        session = nil
        save()
        CloudSync.shared.reset()
        Store.shared.switchAccount(nil)
    }

    /// The refresh in progress, shared so two requests never use the same refresh token twice
    /// (Supabase would reject the second one and the person would be signed out).
    private var refreshing: Task<String, Error>?

    /// A valid access token, refreshed when it is about to expire.
    func token() async throws -> String {
        guard let s = session else { throw Cloud.CloudError("Not signed in.") }
        if s.expiresAt.timeIntervalSinceNow > 60 { return s.accessToken }
        if let r = refreshing { return try await r.value }
        let task = Task<String, Error> { @MainActor in
            defer { self.refreshing = nil }
            return try await self.refresh(s)
        }
        refreshing = task
        return try await task.value
    }

    private func refresh(_ s: CloudSession) async throws -> String {
        do {
            let obj = try await Self.authCall("token?grant_type=refresh_token", ["refresh_token": s.refreshToken])
            try adopt(obj)
        } catch let e as Cloud.CloudError {
            // A refresh token that was revoked or already used means signing in again.
            if e.message.lowercased().contains("refresh") || e.message.lowercased().contains("invalid") {
                session = nil
                save()
            }
            throw e
        }
        guard let t = session?.accessToken else { throw Cloud.CloudError("Not signed in.") }
        return t
    }

    // MARK: Internals

    private func run(_ work: @escaping @MainActor () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            if let uid = session?.userID {
                Store.shared.switchAccount(uid)
                await CloudSync.shared.start()
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func adopt(_ obj: [String: Any]) throws {
        guard let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String,
              let user = obj["user"] as? [String: Any],
              let id = user["id"] as? String else {
            throw Cloud.CloudError("Unexpected reply from the server.")
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? Double(obj["expires_in"] as? Int ?? 3600)
        session = CloudSession(accessToken: access, refreshToken: refresh,
                               expiresAt: Date().addingTimeInterval(expiresIn),
                               userID: id, email: (user["email"] as? String) ?? "")
        save()
    }

    nonisolated private static func authCall(_ path: String, _ body: [String: Any],
                                             method: String = "POST", bearer: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: "\(Cloud.url)/auth/v1/\(path)") else { throw Cloud.CloudError("Bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(Cloud.anonKey, forHTTPHeaderField: "apikey")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Cloud.CloudError(Cloud.message(from: data, status: status)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Database calls (PostgREST)

enum CloudAPI {
    /// GET /rest/v1/<table>?<query> → rows
    @MainActor
    static func select(_ table: String, _ query: [URLQueryItem]) async throws -> [[String: Any]] {
        let data = try await call("GET", table, query: query, body: nil, prefer: nil)
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Insert or update rows by primary key.
    @MainActor
    static func upsert(_ table: String, _ rows: [[String: Any]]) async throws {
        _ = try await call("POST", table, query: [], body: rows,
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    @MainActor
    static func insert(_ table: String, _ rows: [[String: Any]]) async throws {
        _ = try await call("POST", table, query: [], body: rows, prefer: "return=minimal")
    }

    @MainActor
    static func update(_ table: String, _ query: [URLQueryItem], _ values: [String: Any]) async throws {
        _ = try await call("PATCH", table, query: query, body: values, prefer: "return=minimal")
    }

    @MainActor
    private static func call(_ method: String, _ table: String, query: [URLQueryItem],
                             body: Any?, prefer: String?) async throws -> Data {
        let token = try await CloudAuth.shared.token()
        guard var comps = URLComponents(string: "\(Cloud.url)/rest/v1/\(table)") else { throw Cloud.CloudError("Bad URL") }
        if !query.isEmpty { comps.queryItems = query }
        // "+" in timestamps must be encoded, URLComponents leaves it as is.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw Cloud.CloudError("Bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(Cloud.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Cloud.CloudError(Cloud.message(from: data, status: status)) }
        return data
    }
}
