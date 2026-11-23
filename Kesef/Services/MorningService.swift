import Foundation
import SwiftData

/// חיבור ל-morning (חשבונית ירוקה) — הפקת מסמכי מס רשמיים דרך תוכנה רשומה.
/// כתובות לפי התיעוד הרשמי: developers.morning.co
@MainActor
final class MorningService {
    enum Environment: String, CaseIterable, Identifiable {
        /// הדגמה מקומית — בלי חשבון ובלי רשת. מסמך מדומה, לא נשלח לשום מקום.
        case demo, sandbox, production
        var id: String { rawValue }
        var label: String {
            switch self {
            case .demo: return "הדגמה — בלי חשבון morning, שום דבר לא נשלח"
            case .sandbox: return "ניסיון (Sandbox) — מפתחות ניסיון, לא מפיק מסמכים אמיתיים"
            case .production: return "אמיתי (Production) — מסמכי מס רשמיים"
            }
        }
        var shortLabel: String { self == .demo ? "הדגמה" : (self == .sandbox ? "ניסיון" : "אמיתי") }
        var tokenURL: URL {
            URL(string: self == .sandbox ? "https://api.sandbox.morning.dev/idp/v1/oauth/token"
                                         : "https://api.morning.co/idp/v1/oauth/token")!
        }
        var apiBase: URL {
            URL(string: self == .sandbox ? "https://sandbox.d.greeninvoice.co.il/api/v1"
                                         : "https://api.greeninvoice.co.il/api/v1")!
        }
    }

    static let envKey = "morningEnvironment"
    static func idAccount(_ e: Environment) -> String { "morningClientId-\(e.rawValue)" }
    static func secretAccount(_ e: Environment) -> String { "morningClientSecret-\(e.rawValue)" }

    static var environment: Environment {
        get { Environment(rawValue: UserDefaults.standard.string(forKey: envKey) ?? "") ?? .demo }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: envKey) }
    }
    /// רשת ניתנת להחלפה — לבדיקות עם תשובות מדומות
    static var session: URLSession = .shared

    /// לבדיקות בלבד: מקור מפתחות חלופי במקום ה-Keychain
    static var credentialOverride: ((Environment) -> (id: String, secret: String)?)?

    static func credentials(_ e: Environment) -> (id: String, secret: String)? {
        if let o = credentialOverride { return o(e) }
        guard let id = KeychainStore.get(idAccount(e)), let secret = KeychainStore.get(secretAccount(e)),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return (id, secret)
    }

    static func isConfigured(_ e: Environment) -> Bool {
        e == .demo || credentials(e) != nil
    }

    struct CreatedDocument {
        var id: String
        var number: Int
        var type: Int
        var url: URL?
        var taxAuthorityError: Int
    }

    enum MorningError: LocalizedError {
        case notConfigured, auth(String), noAPIAccess, api(Int, String), network(String), badResponse
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "לא הוגדרו מפתחות morning. הגדר אותם במסך ההגדרות של הקבלות."
            case .auth(let m): return "ההתחברות ל-morning נכשלה: \(m)"
            case .noAPIAccess: return "המנוי ב-morning לא כולל גישת API. יש לשדרג מנוי או לבדוק מול morning."
            case .api(let code, let m): return "morning החזירה שגיאה (\(code)): \(m)"
            case .network(let m): return "אין חיבור לאינטרנט או שהחיבור נכשל: \(m)"
            case .badResponse: return "התקבלה תשובה לא צפויה מ-morning."
            }
        }
    }

    private static var cachedToken: (env: Environment, token: String, expires: Date)?
    private static var demoCounter = 0
    static func resetForTests() { cachedToken = nil; demoCounter = 0 }

    private static func accessToken(_ env: Environment) async throws -> String {
        if let c = cachedToken, c.env == env, c.expires.timeIntervalSinceNow > 60 { return c.token }
        guard let creds = credentials(env) else { throw MorningError.notConfigured }
        let id = creds.id, secret = creds.secret
        var req = URLRequest(url: env.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "client_credentials", "client_id": id, "client_secret": secret
        ])
        let (data, resp) = try await send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard resp.statusCode == 200, let token = json?["accessToken"] as? String else {
            let err = json?["error"] as? String ?? ""
            if err == "unauthorized_client" { throw MorningError.noAPIAccess }
            let desc = json?["error_description"] as? String ?? err
            throw MorningError.auth(desc.isEmpty ? "קוד \(resp.statusCode)" : desc)
        }
        let exp = (json?["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date().addingTimeInterval(3000)
        cachedToken = (env, token, exp)
        return token
    }

    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw MorningError.badResponse }
            return (data, http)
        } catch let e as MorningError { throw e }
        catch { throw MorningError.network(error.localizedDescription) }
    }

    /// בדיקת חיבור: מבקש טוקן בלבד (לא יוצר שום מסמך)
    static func testConnection(_ env: Environment) async throws {
        if env == .demo { return }
        cachedToken = nil
        _ = try await accessToken(env)
    }

    /// מפיק מסמך רשמי. פעולה שאי אפשר לבטל בסביבה האמיתית (אפשר רק להפיק מסמך מבטל/זיכוי).
    static func createDocument(_ draft: MorningDocumentDraft) async throws -> CreatedDocument {
        let env = environment
        if env == .demo {
            try await Task.sleep(nanoseconds: 600_000_000)
            demoCounter += 1
            return CreatedDocument(id: "demo-\(UUID().uuidString)", number: 1000 + demoCounter, type: draft.type.rawValue,
                                   url: nil, taxAuthorityError: 0)
        }
        let token = try await accessToken(env)
        var req = URLRequest(url: env.apiBase.appendingPathComponent("documents"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: draft.requestBody())
        let (data, resp) = try await send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(resp.statusCode), let json, let id = json["id"] as? String else {
            if resp.statusCode == 401 { cachedToken = nil }
            let code = json?["errorCode"] as? Int ?? resp.statusCode
            let msg = json?["errorMessage"] as? String ?? json?["message"] as? String
                ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw MorningError.api(code, msg)
        }
        let urls = json["url"] as? [String: Any]
        let link = (urls?["he"] as? String) ?? (urls?["origin"] as? String)
        return CreatedDocument(id: id, number: json["number"] as? Int ?? 0, type: json["type"] as? Int ?? draft.type.rawValue,
                               url: link.flatMap(URL.init(string:)),
                               taxAuthorityError: json["taxAuthorityConfirmationLastError"] as? Int ?? 0)
    }

    /// רושם את ההכנסה באפליקציה אחרי הפקת מסמך שמתעד תשלום — נכנס למע״מ ולחלוקה עם השותף
    static func recordIncome(context: ModelContext, draft: MorningDocumentDraft, doc: CreatedDocument,
                             categoryID: UUID?, accountID: UUID?) throws -> Entry? {
        // מסמך ניסיון לא נרשם כהכנסה אמיתית
        guard draft.type.recordsPayment, environment == .production else { return nil }
        let e = Entry(kind: .income, status: .confirmed, amount: draft.amountIncludingVAT, date: draft.date,
                      title: "\(draft.clientName) — \(draft.itemDescription)", scope: .business,
                      categoryID: categoryID, accountID: accountID, source: .manual)
        e.paymentMethod = draft.payment.ledgerMethod
        e.externalRef = "morning:\(doc.id)"
        let env = ""
        e.note = "\(draft.type.label) מס׳ \(doc.number)\(env)" + (doc.url.map { "\n\($0.absoluteString)" } ?? "")
        let vat = AppSettings.vat
        if vat.isRegistered && !draft.vatExempt {
            e.vatMinor = VatEngine.vatIncluded(in: draft.amountIncludingVAT, rateBasisPoints: vat.rateBasisPoints).minorUnits
        }
        context.insert(e)
        try context.save()
        return e
    }
}
