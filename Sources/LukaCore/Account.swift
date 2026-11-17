import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What Soniox itself reports about the account, as opposed to Luka's own count of audio it sent.
public enum SonioxAccount {
    /// The organization's prepaid balance. Needs an organization API key (`snx_org_…`).
    public struct Balance: Equatable, Sendable {
        public var availableUSD: Double
        public var freeUSD: Double
        public var usedUSD: Double
        public var invoiced: Bool
        public var exhausted: Bool
    }

    /// Organization endpoints live only on the main host, whatever the project's region.
    public static func balanceRequest(orgKey: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.soniox.com/v1/organization/balance")!)
        r.setValue("Bearer \(orgKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        return r
    }

    /// This project's real cost from the first of the month (UTC) to now. Works with the normal project key.
    public static func monthCostRequest(apiKey: String, apiHost: String, now: Date = .now) -> URLRequest {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        var c = URLComponents(string: "https://\(apiHost)/v1/usage/summary")!
        c.queryItems = [URLQueryItem(name: "start_time", value: f.string(from: start)),
                        URLQueryItem(name: "end_time", value: f.string(from: end))]
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        return r
    }

    public struct Failure: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func parseBalance(_ data: Data) throws -> Balance {
        let json = try object(data)
        guard let available = decimal(json["available_balance_usd"]) else { throw Failure(message: "Unexpected balance reply") }
        return Balance(availableUSD: available, freeUSD: decimal(json["free_balance_usd"]) ?? 0,
                       usedUSD: decimal(json["used_balance_usd"]) ?? 0,
                       invoiced: json["invoice_billing_enabled"] as? Bool ?? false,
                       exhausted: json["balance_exhausted"] as? Bool ?? false)
    }

    /// Total cost in USD of the usage summary.
    public static func parseMonthCost(_ data: Data) throws -> Double {
        let json = try object(data)
        guard let total = json["total"] as? [String: Any] else { throw Failure(message: "Unexpected usage reply") }
        return decimal(total["total_cost_usd"]) ?? 0
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Unexpected reply")
        }
        if let message = json["message"] as? String, json["error_type"] != nil || json["status_code"] != nil {
            throw Failure(message: message)
        }
        return json
    }

    /// Soniox sends money as decimal strings.
    private static func decimal(_ value: Any?) -> Double? {
        if let s = value as? String { return Double(s) }
        return value as? Double
    }
}
