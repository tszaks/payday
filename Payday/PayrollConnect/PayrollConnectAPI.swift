import Foundation
import PaydayCore
import Supabase

/// One pay stub as the `payroll-connect` edge function returns it: integer
/// cents and ISO days, read off the stub and nothing more
/// (`supabase/functions/payroll-connect/normalize.ts`). What its lines mean
/// (tips, gratuity, taxes) is decided by `PayStubFigures` in PaydayCore.
struct PayrollStatement: Codable, Equatable, Sendable, Identifiable {
    var id: String { sourceID }

    let sourceID: String
    let linkID: String
    let providerName: String?
    let employerName: String?
    /// "YYYY-MM-DD".
    let payDate: String
    let periodStart: String?
    let periodEnd: String?
    let grossPayCents: Int?
    let netPayCents: Int?
    /// Decimal string as printed ("80.00").
    let hours: String?
    let regularCents: Int?
    let overtimeCents: Int?
    let earnings: [PayStubLine]
    let deductions: [PayStubLine]

    var figures: PayStubFigures {
        PayStubFigures(earnings: earnings, deductions: deductions)
    }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case linkID = "link_id"
        case providerName = "provider_name"
        case employerName = "employer_name"
        case payDate = "pay_date"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case grossPayCents = "gross_cents"
        case netPayCents = "net_cents"
        case hours
        case regularCents = "regular_cents"
        case overtimeCents = "overtime_cents"
        case earnings
        case deductions
    }
}

struct PayrollLink: Codable, Equatable, Sendable, Identifiable {
    var id: String { linkID }

    let linkID: String
    let status: String?
    let providerID: String?
    let providerName: String?
    let employerName: String?
    let updatedAt: String?
    /// When the server will accept the next "Check for new paystubs" for
    /// this link; nil when it would accept one now.
    let refreshAvailableAt: String?

    enum CodingKeys: String, CodingKey {
        case linkID = "link_id"
        case status
        case providerID = "provider_id"
        case providerName = "provider_name"
        case employerName = "employer_name"
        case updatedAt = "updated_at"
        case refreshAvailableAt = "refresh_available_at"
    }

    /// What the connection screen calls it: the employer when Truv knows it,
    /// else the payroll provider.
    var displayName: String {
        employerName ?? providerName ?? "Payroll"
    }

    var isConnected: Bool { status == "done" }

    /// Truv's task states while a sign-in or a read is still running.
    static let inProgressStatuses: Set<String> = ["new", "login", "mfa", "parse", "full_parse", "pending"]

    /// Not done and not running: the sign-in failed or expired (a changed
    /// password, an MFA session that ran out, a locked account) or Truv
    /// could not read the account. Signing in again is the way out.
    var needsSignIn: Bool {
        guard !isConnected else { return false }
        guard let status else { return false }
        return !Self.inProgressStatuses.contains(status)
    }
}

enum PayrollEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

struct PayrollStatus: Codable, Equatable, Sendable {
    let environment: PayrollEnvironment
    let links: [PayrollLink]
}

struct PayrollPaystubs: Codable, Equatable, Sendable {
    let environment: PayrollEnvironment
    let links: [PayrollLink]
    let paystubs: [PayrollStatement]
}

struct PayrollBridgeToken: Codable, Sendable {
    let environment: PayrollEnvironment
    let bridgeToken: String

    enum CodingKeys: String, CodingKey {
        case environment
        case bridgeToken = "bridge_token"
    }
}

/// What the server refused, by its stable code.
struct PayrollConnectError: LocalizedError, Equatable {
    let status: Int
    let code: String
    let message: String

    var errorDescription: String? { message }

    static let offline = PayrollConnectError(status: 0, code: "offline", message: "Payday couldn't reach the server. Try again.")
}

/// The app's side of `payroll-connect`. The protocol is the test seam; the
/// app uses `PayrollConnectService`.
protocol PayrollConnectAPI: Sendable {
    func status() async throws -> PayrollStatus
    /// A Bridge token. With `linkID`, Bridge opens on that existing link so
    /// the person signs in again (update mode); without, it makes a new one.
    func bridgeToken(linkID: String?) async throws -> PayrollBridgeToken
    func exchange(publicToken: String) async throws -> PayrollLink
    func paystubs(since: String?) async throws -> PayrollPaystubs
    func refresh(linkID: String) async throws
    func disconnect(linkID: String) async throws
    /// Account deletion: removes the person's Truv user, every link and the
    /// payroll data Truv read.
    func forget() async throws
}

/// Calls the edge function with the signed-in person's session: the
/// Supabase client attaches the access token, and the function checks it
/// before it talks to Truv. The Truv keys never reach this process.
struct PayrollConnectService: PayrollConnectAPI {
    static let functionName = "payroll-connect"

    private let client: SupabaseClient

    init(client: SupabaseClient = PaydaySupabase.client) {
        self.client = client
    }

    private struct Envelope<T: Decodable>: Decodable {
        let data: T
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
        }
        let error: Body
    }

    private struct Empty: Decodable {}

    private func call<T: Decodable>(_ body: [String: String]) async throws -> T {
        do {
            let envelope: Envelope<T> = try await client.functions.invoke(
                Self.functionName,
                options: FunctionInvokeOptions(method: .post, body: body)
            )
            return envelope.data
        } catch let FunctionsError.httpError(code, data) {
            if let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw PayrollConnectError(status: code, code: decoded.error.code, message: decoded.error.message)
            }
            throw PayrollConnectError(status: code, code: "http_\(code)", message: "Payroll connection failed. Try again.")
        } catch let error as PayrollConnectError {
            throw error
        } catch is DecodingError {
            throw PayrollConnectError(status: 0, code: "bad_response", message: "Payday couldn't read the answer. Try again.")
        } catch {
            throw PayrollConnectError.offline
        }
    }

    func status() async throws -> PayrollStatus {
        try await call(["action": "status"])
    }

    func bridgeToken(linkID: String?) async throws -> PayrollBridgeToken {
        var body = ["action": "link_token"]
        if let linkID { body["link_id"] = linkID }
        return try await call(body)
    }

    func exchange(publicToken: String) async throws -> PayrollLink {
        struct Exchanged: Decodable { let link: PayrollLink }
        let result: Exchanged = try await call(["action": "exchange", "public_token": publicToken])
        return result.link
    }

    func paystubs(since: String?) async throws -> PayrollPaystubs {
        var body = ["action": "paystubs"]
        if let since { body["since"] = since }
        return try await call(body)
    }

    func refresh(linkID: String) async throws {
        let _: Empty = try await call(["action": "refresh", "link_id": linkID])
    }

    func disconnect(linkID: String) async throws {
        let _: Empty = try await call(["action": "disconnect", "link_id": linkID])
    }

    func forget() async throws {
        let _: Empty = try await call(["action": "forget"])
    }
}
