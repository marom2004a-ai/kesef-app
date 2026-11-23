import Foundation

/// מפענח את "קלט הקיצור" של אוטומציית Wallet כשהוא מגיע כטקסט אחד (ב-iOS החדש אי אפשר תמיד לבחור את השדות בנפרד).
/// גישה זהירה: מחלצים סכום רק כשיש סימן מטבע או פורמט עשרוני ברור; אם לא בטוחים — משאירים ריק והעסקה נפתחת להשלמה.
public enum WalletTextParser {
    public struct Result: Equatable, Sendable {
        public var amount: Money?
        public var merchant: String?
        public var card: String?
    }

    static let currencyMarks = ["₪", "ILS", "NIS", "ש\"ח", "ש״ח", "שח", "$", "€", "USD", "EUR"]
    static let amountLabels = ["amount", "סכום", "סך", "total"]
    static let merchantLabels = ["merchant", "סוחר", "בית עסק", "בית העסק", "name", "שם"]
    static let cardLabels = ["card", "כרטיס", "pass"]

    public static func parse(_ raw: String) -> Result {
        var result = Result()
        let text = raw.replacingOccurrences(of: "\r", with: "\n")
        // פיצול לשורות ולחלקים לפי פסיקים/נקודה-פסיק כשהכול בשורה אחת
        var parts: [String] = text.split(whereSeparator: { $0 == "\n" }).map(String.init)
        if parts.count <= 1 { parts = text.split(whereSeparator: { $0 == ";" || $0 == "|" }).map(String.init) }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        func labeled(_ part: String, _ labels: [String]) -> String? {
            let lower = part.lowercased()
            for l in labels {
                if lower.hasPrefix(l + ":") || lower.hasPrefix(l + " :") || lower.hasPrefix(l + "=") {
                    return part.drop(while: { $0 != ":" && $0 != "=" }).dropFirst().trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        // 1. שדות עם תווית (Amount: ..., Merchant: ...)
        for p in parts {
            if result.amount == nil, let v = labeled(p, amountLabels) { result.amount = AmountParser.parse(v)?.absolute }
            if result.merchant == nil, let v = labeled(p, merchantLabels), !v.isEmpty { result.merchant = v }
            if result.card == nil, let v = labeled(p, cardLabels), !v.isEmpty { result.card = v }
        }

        func hasCurrency(_ s: String) -> Bool { currencyMarks.contains { s.contains($0) } }
        func looksLikeCard(_ s: String) -> Bool {
            s.contains("••") || s.contains("•") || s.contains("****") || cardLabels.contains { s.lowercased().contains($0) }
        }
        func isAmountOnly(_ s: String) -> Bool {
            let stripped = s.filter { !$0.isWhitespace }
            let rest = currencyMarks.reduce(stripped) { $0.replacingOccurrences(of: $1, with: "") }
            return !rest.isEmpty && rest.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" || $0 == "\u{200E}" || $0 == "\u{200F}" }
        }

        // 2. סכום: חלק עם סימן מטבע, אחרת חלק שהוא רק מספר עשרוני עם 2 ספרות
        if result.amount == nil {
            if let p = parts.first(where: { hasCurrency($0) && !looksLikeCard($0) }) {
                result.amount = extractAmount(from: p)
            } else if let p = parts.first(where: { isAmountOnly($0) && $0.range(of: #"\d[.,]\d{2}$"#, options: .regularExpression) != nil }) {
                result.amount = AmountParser.parse(p)?.absolute
            }
        }

        // 3. כרטיס
        if result.card == nil, let p = parts.first(where: { looksLikeCard($0) && !hasCurrency($0) }) { result.card = p }

        // 4. בית עסק: החלק הראשון שיש בו אותיות ואינו סכום/כרטיס/תאריך
        if result.merchant == nil {
            result.merchant = parts.first { p in
                p.contains(where: { $0.isLetter }) && !isAmountOnly(p) && !looksLikeCard(p) && p != result.card
                    && !(hasCurrency(p) && p.filter(\.isLetter).count <= 4)
                    && CSVImportEngine.parseDate(p) == nil
            }.map { stripAmount(from: $0) }
        }
        if let m = result.merchant, m.isEmpty { result.merchant = nil }
        if let a = result.amount, !a.isPositive { result.amount = nil }
        return result
    }

    /// מחלץ את המספר שצמוד לסימן המטבע ("קפה ₪12.50 בכרטיס" → 12.50)
    static func extractAmount(from s: String) -> Money? {
        let pattern = #"(?:₪|ILS|NIS|\$|€)\s*-?\d[\d,]*(?:[.,]\d{1,2})?|-?\d[\d,]*(?:[.,]\d{1,2})?\s*(?:₪|ILS|NIS|ש"ח|ש״ח|שח|\$|€)"#
        guard let r = s.range(of: pattern, options: .regularExpression) else { return AmountParser.parse(s)?.absolute }
        return AmountParser.parse(String(s[r]))?.absolute
    }

    static func stripAmount(from s: String) -> String {
        let pattern = #"(?:₪|ILS|NIS|\$|€)\s*-?\d[\d,]*(?:[.,]\d{1,2})?|-?\d[\d,]*(?:[.,]\d{1,2})?\s*(?:₪|ILS|NIS|ש"ח|ש״ח|שח|\$|€)"#
        return s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—,·|")))
    }
}
