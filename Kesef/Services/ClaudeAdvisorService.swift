import Foundation
import SwiftData

/// יועצת פיננסית מבוססת Claude (Anthropic Messages API, HTTPS ישיר — אין SDK רשמי ל-Swift).
/// נשלח רק סיכום הנתונים (AdvisorContext) והשאלות, ורק אחרי הסכמה מפורשת. המפתח שמור ב-Keychain.
@MainActor
final class ClaudeAdvisorService {
    static let keychainAccount = "anthropicAPIKey"
    static let consentKey = "advisorConsentGiven"
    static let model = "claude-opus-5-5"
    /// מחירון לדולר למיליון טוקנים (Claude Opus 5.5) — להערכת עלות בלבד
    static let inputPerMillion = Decimal(4), outputPerMillion = Decimal(20), cacheReadPerMillion = Decimal(string: "0.20")!

    struct Usage {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        /// עלות משוערת בדולרים
        var estimatedUSD: Decimal {
            let inp = Decimal(input) * ClaudeAdvisorService.inputPerMillion
            let cw = Decimal(cacheWrite) * ClaudeAdvisorService.inputPerMillion * Decimal(string: "1.25")!
            let cr = Decimal(cacheRead) * ClaudeAdvisorService.cacheReadPerMillion
            let out = Decimal(output) * ClaudeAdvisorService.outputPerMillion
            return (inp + cw + cr + out) / 1_000_000
        }
    }

    enum AdvisorError: LocalizedError {
        case noKey, invalidKey, rateLimited, overloaded, server(Int, String), network(String), refusal, badResponse
        var errorDescription: String? {
            switch self {
            case .noKey: return "לא הוגדר מפתח API. הגדר אותו במסך היועצת."
            case .invalidKey: return "מפתח ה-API לא תקין או בוטל. בדוק אותו ב-platform.claude.com."
            case .rateLimited: return "יותר מדי בקשות כרגע. נסה שוב בעוד דקה."
            case .overloaded: return "השירות עמוס כרגע. נסה שוב בעוד רגע."
            case .server(let code, let msg): return "שגיאה מהשרת (\(code)): \(msg)"
            case .network(let msg): return "אין חיבור לאינטרנט או שהחיבור נכשל: \(msg)"
            case .refusal: return "היועצת לא יכלה לענות על השאלה הזו. נסה לנסח אחרת."
            case .badResponse: return "התקבלה תשובה לא צפויה מהשרת."
            }
        }
    }

    /// היסטוריית השיחה בפורמט ה-API. תשובות העוזרת נשמרות כמו שהתקבלו (כולל בלוקי thinking) — חובה להחזיר אותן ללא שינוי.
    private(set) var apiMessages: [[String: Any]] = []
    private(set) var usage = Usage()
    private var dataSummary = ""

    static var hasKey: Bool { KeychainStore.get(keychainAccount)?.isEmpty == false }
    static var hasConsent: Bool { UserDefaults.standard.bool(forKey: consentKey) }

    static let instructions = """
    את יועצת פיננסית אישית באפליקציית ניהול כספים של עצמאי בישראל — בעלים של עסק לאילוף כלבים ופנסיון ("חברים על 4") עם שותף. \
    עני תמיד בעברית, בגובה העיניים, קצר וממוקד, עם מספרים מדויקים מהנתונים.

    עקרונות:
    - התבססי רק על הנתונים שבסיכום. אל תמציאי הוצאות, הכנסות או מגמות. אם חסר מידע — אמרי מה חסר.
    - הבחיני בין כסף אישי לעסקי, ובין נתון מאומת לתחזית. הכנסה צפויה איננה כסף בחשבון.
    - כשאת ממליצה לחסוך: צייני את הקטגוריה או בית העסק, כמה הוצא, כמה אפשר לחסוך בחודש ובשנה, ופעולה מעשית אחת.
    - חפשי במיוחד: הוצאות קטנות שחוזרות הרבה (קפה, משלוחים), מנויים כפולים או שלא בשימוש, קטגוריות שעלו, חריגות מתקציב, \
    ותשלומים קבועים שאפשר להוזיל.
    - זכרי שההכנסה משתנה: המליצי על כרית לחודשים חלשים, ועל יעד חיסכון ריאלי לפי הממוצע.
    - מע״מ וחלק השותף אינם כסף פנוי.
    - ללא כוכביות או כותרות מרובות — טקסט פשוט, רשימה קצרה כשצריך.
    - את לא יועצת השקעות מורשית ולא רואת חשבון; בשאלות מס או השקעות — הפני לאיש מקצוע.
    """

    /// מתחיל שיחה חדשה עם סיכום נתונים עדכני
    func startConversation(context: ModelContext) {
        apiMessages = []
        usage = Usage()
        dataSummary = Self.buildSummary(context: context)
    }

    static func buildSummary(context: ModelContext) -> String {
        let l = Ledger(context: context)
        let vat = AppSettings.vat
        return AdvisorContext.build(AdvisorContextInput(
            now: .now, entries: l.entries().map(\.snapshot), categories: l.categories().map(\.snapshot),
            recurring: l.recurring().map(\.snapshot), budgets: l.budgets().map(\.snapshot),
            accounts: l.accounts().map(\.snapshot), partner: l.partnerSettings(), vat: vat.isRegistered ? vat : nil,
            vatDeductibleBP: l.vatDeductibleMap(), monthlySavingsTarget: AppSettings.monthlySavingsTarget,
            reserve: AppSettings.reserve, goals: l.goals().map { (title: $0.title, target: $0.target, saved: $0.saved) }))
    }

    var summaryCharacterCount: Int { dataSummary.count }

    /// שולח שאלה ומחזיר את טקסט התשובה
    func ask(_ question: String) async throws -> String {
        guard let key = KeychainStore.get(Self.keychainAccount), !key.isEmpty else { throw AdvisorError.noKey }
        apiMessages.append(["role": "user", "content": question])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4000,
            "system": [
                ["type": "text", "text": Self.instructions],
                ["type": "text", "text": "סיכום הנתונים הפיננסיים של המשתמש:\n\n" + dataSummary,
                 "cache_control": ["type": "ephemeral"]]
            ],
            "messages": apiMessages,
            // שיחה: מאמץ נמוך — מהיר וזול יותר
            "output_config": ["effort": "low"],
            // אם המודל מסרב — מעבר אוטומטי למודל חלופי בצד השרת
            "fallbacks": "default"
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch {
            apiMessages.removeLast()
            throw AdvisorError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            apiMessages.removeLast()
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            switch status {
            case 401, 403: throw AdvisorError.invalidKey
            case 429: throw AdvisorError.rateLimited
            case 529: throw AdvisorError.overloaded
            default: throw AdvisorError.server(status, msg)
            }
        }

        if let u = json["usage"] as? [String: Any] {
            usage.input += u["input_tokens"] as? Int ?? 0
            usage.output += u["output_tokens"] as? Int ?? 0
            usage.cacheRead += u["cache_read_input_tokens"] as? Int ?? 0
            usage.cacheWrite += u["cache_creation_input_tokens"] as? Int ?? 0
        }
        let stop = json["stop_reason"] as? String
        guard let content = json["content"] as? [[String: Any]] else { apiMessages.removeLast(); throw AdvisorError.badResponse }
        if stop == "refusal" {
            apiMessages.removeLast()
            throw AdvisorError.refusal
        }
        // שומרים את התוכן המלא כמו שהוא (כולל thinking) לתור הבא
        apiMessages.append(["role": "assistant", "content": content])
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        guard !text.isEmpty else { throw AdvisorError.badResponse }
        return stop == "max_tokens" ? text + "\n\n(התשובה נחתכה — בקש המשך)" : text
    }
}
