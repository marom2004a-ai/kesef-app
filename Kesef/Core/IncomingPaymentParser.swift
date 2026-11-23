import Foundation

/// מפענח הודעת SMS על תשלום נכנס (ביט / פייבוקס / העברה בנקאית) לסכום ושם המשלם.
/// זהיר: סכום רק כשיש סימן מטבע או מילת סכום ליד המספר; שם — רק מתבנית ברורה. מה שלא בטוח נשאר ריק ומושלם באישור.
public enum IncomingPaymentParser {
    public struct Result: Equatable, Sendable {
        public var amount: Money?
        public var payer: String?
        public var source: String?
    }

    static let currency = #"(?:₪|ש\"ח|ש״ח|שח|ILS|NIS)"#
    static let number = #"(\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)"#

    public static func parse(_ raw: String) -> Result {
        let text = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        var r = Result()

        // סכום: "₪250" / "250 ₪" / "250.50 ש״ח" / "סכום: 250"
        let patterns = [currency + #"\s?"# + number, number + #"\s?"# + currency, #"(?:סכום|בסך)[:\s]+"# + number]
        for p in patterns {
            if let m = firstGroup(p, in: text), let a = AmountParser.parse(m)?.absolute, a.isPositive { r.amount = a; break }
        }

        // משלם: "X העביר/ה לך", "X שלח/ה לך", "קיבלת ... מ-X" / "מאת X" / "from X"
        let payerPatterns = [
            #"([^\d₪,.:!?]{2,40}?)\s+(?:העביר|העבירה|שלח|שלחה|העבירו|שילם|שילמה)\s+לך"#,
            #"(?:מאת|מ־|מ-)\s*([^\d₪,.:!?]{2,40}?)(?:\s+(?:באמצעות|בביט|דרך|ב-?Bit)|[,.!]|$)"#,
            #"(?i)from\s+([A-Za-z֐-׿][^\d,.:!?]{1,40}?)(?:[,.!]|$)"#
        ]
        for p in payerPatterns {
            if let m = firstGroup(p, in: text) {
                let name = clean(m)
                if name.count >= 2 && !isNoise(name) { r.payer = name; break }
            }
        }

        let lower = text.lowercased()
        if lower.contains("bit") || text.contains("ביט") { r.source = "Bit" }
        else if lower.contains("paybox") || text.contains("פייבוקס") { r.source = "PayBox" }
        else if text.contains("העברה") || text.contains("זיכוי") { r.source = "העברה בנקאית" }
        return r
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1,
              m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for prefix in ["היי", "שלום", "הודעה", "ביט:", "Bit:", "bit:"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func isNoise(_ s: String) -> Bool {
        ["לך", "אליך", "חשבונך", "החשבון", "ביט", "bit", "Bit"].contains(s)
    }
}
