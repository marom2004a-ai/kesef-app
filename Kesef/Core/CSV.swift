import Foundation

// MARK: - פענוח CSV

public enum CSVParser {
    /// מזהה מפריד (פסיק / נקודה-פסיק / טאב) לפי השורה הראשונה
    public static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).first.map(String.init) ?? text
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for ch in firstLine {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes, counts[ch] != nil { counts[ch]! += 1 }
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key != ",") }?.key ?? ","
    }

    public static func parse(_ raw: String, delimiter: Character? = nil) -> [[String]] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let delim = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(ch) }
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == delim {
                row.append(field); field = ""
            } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) { rows.append(row) }
                row = []
                if ch == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
            } else {
                field.append(ch)
            }
            i += 1
        }
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    public static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

// MARK: - ייבוא תנועות

public struct CSVColumnMapping: Hashable, Sendable {
    public var hasHeader: Bool
    public var dateColumn: Int
    public var descriptionColumn: Int
    /// עמודת סכום אחת (חיובי/שלילי) — או חובה/זכות בנפרד
    public var amountColumn: Int?
    public var debitColumn: Int?
    public var creditColumn: Int?
    /// בקובצי כרטיס אשראי סכום חיובי = חיוב (הוצאה)
    public var positiveIsExpense: Bool
    /// true = יום/חודש/שנה (ישראלי). false = חודש/יום/שנה
    public var dayFirst: Bool
    /// עמודת סכום המע״מ (אם הדוח כולל אותה)
    public var vatColumn: Int?

    public init(hasHeader: Bool = true, dateColumn: Int = 0, descriptionColumn: Int = 1, amountColumn: Int? = 2,
                debitColumn: Int? = nil, creditColumn: Int? = nil, positiveIsExpense: Bool = false, dayFirst: Bool = true,
                vatColumn: Int? = nil) {
        self.hasHeader = hasHeader; self.dateColumn = dateColumn; self.descriptionColumn = descriptionColumn
        self.amountColumn = amountColumn; self.debitColumn = debitColumn; self.creditColumn = creditColumn
        self.positiveIsExpense = positiveIsExpense; self.dayFirst = dayFirst; self.vatColumn = vatColumn
    }
}

public struct ImportedRow: Sendable, Identifiable, Hashable {
    public var id: Int { rowIndex }
    public var rowIndex: Int
    public var date: Date?
    public var description: String
    /// שלילי = הוצאה, חיובי = הכנסה/זיכוי
    public var signedAmount: Money?
    public var error: String?
    public var isDuplicate: Bool = false
    /// סכום המע״מ מהדוח (תמיד חיובי), אם יש עמודה כזו
    public var vat: Money? = nil
    public var isValid: Bool { error == nil && date != nil && signedAmount != nil }
}

public enum CSVImportEngine {

    static let dateHeaders = ["תאריך", "date", "תאריך עסקה", "תאריך רכישה", "תאריך ערך"]
    static let descHeaders = ["תיאור", "בית עסק", "שם בית העסק", "פרטים", "תיאור התנועה", "description", "merchant", "payee", "ספק", "שם הספק", "לקוח", "שם הלקוח", "אסמכתא"]
    static let amountHeaders = ["סכום", "סכום חיוב", "סכום העסקה", "amount", "סכום בש\"ח", "סכום בשח"]
    static let debitHeaders = ["חובה", "debit", "בחובה"]
    static let creditHeaders = ["זכות", "credit", "בזכות"]
    static let vatHeaders = ["מע\"מ", "מע״מ", "מעמ", "vat", "סכום מע\"מ", "סכום מעמ"]

    /// ניחוש מיפוי עמודות לפי כותרות
    public static func guessMapping(_ table: [[String]]) -> CSVColumnMapping {
        var m = CSVColumnMapping()
        guard let header = table.first else { return m }
        let lower = header.map { $0.lowercased() }
        func find(_ keys: [String]) -> Int? {
            for k in keys { if let i = lower.firstIndex(where: { $0 == k.lowercased() }) { return i } }
            for k in keys { if let i = lower.firstIndex(where: { $0.contains(k.lowercased()) }) { return i } }
            return nil
        }
        // עמודת מע״מ בלבד: מזכירה מע״מ ולא "כולל/ללא/לפני"
        let vatKeys = vatHeaders.map { $0.lowercased() }
        func isVATOnly(_ i: Int) -> Bool {
            !lower[i].contains("כולל") && !lower[i].contains("ללא") && !lower[i].contains("לפני")
                && vatKeys.contains(where: { lower[i].contains($0) })
        }
        let d = find(dateHeaders), desc = find(descHeaders)
        // עמודת הסכום: עדיפות ל"כולל מע״מ", ואף פעם לא עמודת המע״מ עצמה
        func firstIndex(_ test: (Int) -> Bool) -> Int? { lower.indices.first(where: test) }
        var amt: Int? = firstIndex { i in
            lower[i].contains("כולל") && amountHeaders.contains(where: { k in lower[i].contains(k.lowercased()) })
        }
        if amt == nil {
            for k in amountHeaders { if let i = firstIndex({ j in !isVATOnly(j) && lower[j] == k.lowercased() }) { amt = i; break } }
        }
        if amt == nil {
            for k in amountHeaders { if let i = firstIndex({ j in !isVATOnly(j) && lower[j].contains(k.lowercased()) }) { amt = i; break } }
        }
        let deb = find(debitHeaders), cre = find(creditHeaders)
        if let v = lower.indices.first(where: { $0 != amt && $0 != desc && isVATOnly($0) }) { m.vatColumn = v }
        m.hasHeader = d != nil || desc != nil || amt != nil
        if let d { m.dateColumn = d }
        if let desc { m.descriptionColumn = desc }
        if let deb, let cre { m.debitColumn = deb; m.creditColumn = cre; m.amountColumn = nil }
        else if let amt { m.amountColumn = amt }
        if !m.hasHeader, let first = table.first {
            // בלי כותרת: עמודת התאריך היא הראשונה שמתפענחת כתאריך
            if let i = first.firstIndex(where: { parseDate($0, dayFirst: true) != nil }) { m.dateColumn = i }
        }
        return m
    }

    /// פענוח תאריך גמיש: 05/11/2026, 5.11.26, 2026-11-05, 05-11-2026 14:30
    public static func parseDate(_ raw: String, dayFirst: Bool = true, calendar cal: FinanceCalendar = .israel) -> Date? {
        // תאריך אקסל: מספר ימים מ-30/12/1899 (למשל 46350)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let serial = Double(trimmed), !trimmed.contains("/"), !trimmed.contains("-"), serial >= 30_000, serial < 80_000 {
            var base = DateComponents(year: 1899, month: 12, day: 30, hour: 12)
            base.timeZone = cal.calendar.timeZone
            guard let origin = cal.calendar.date(from: base) else { return nil }
            return cal.calendar.date(byAdding: .day, value: Int(serial), to: origin)
        }
        let parts = raw.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard parts.count >= 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return nil }
        var y: Int, mo: Int, d: Int
        if parts[0].count == 4 { y = a; mo = b; d = c }
        else {
            y = c
            if dayFirst { d = a; mo = b } else { mo = a; d = b }
            if parts[2].count <= 2 { y += 2000 }
        }
        guard (1...12).contains(mo), (1...31).contains(d), (1990...2100).contains(y) else { return nil }
        var comps = DateComponents(year: y, month: mo, day: d, hour: 12)
        comps.timeZone = cal.calendar.timeZone
        guard let date = cal.calendar.date(from: comps),
              cal.calendar.component(.day, from: date) == d else { return nil }
        return date
    }

    public static func rows(from table: [[String]], mapping m: CSVColumnMapping) -> [ImportedRow] {
        var result: [ImportedRow] = []
        let body = m.hasHeader ? Array(table.dropFirst()) : table
        for (i, cols) in body.enumerated() {
            let index = i + (m.hasHeader ? 2 : 1)
            func col(_ c: Int?) -> String { guard let c, c >= 0, c < cols.count else { return "" }; return cols[c] }
            var row = ImportedRow(rowIndex: index, date: nil, description: col(m.descriptionColumn), signedAmount: nil, error: nil)
            row.date = parseDate(col(m.dateColumn), dayFirst: m.dayFirst)
            if let amtCol = m.amountColumn {
                if var amount = AmountParser.parse(col(amtCol)) {
                    if m.positiveIsExpense { amount = -amount }
                    row.signedAmount = amount
                }
            } else {
                let debit = AmountParser.parse(col(m.debitColumn))?.absolute ?? .zero
                let credit = AmountParser.parse(col(m.creditColumn))?.absolute ?? .zero
                if !debit.isZero || !credit.isZero { row.signedAmount = credit - debit }
            }
            if let vc = m.vatColumn { row.vat = AmountParser.parse(col(vc))?.absolute }
            if row.date == nil { row.error = "תאריך לא מזוהה: \(col(m.dateColumn))" }
            else if row.signedAmount == nil || row.signedAmount!.isZero { row.error = "סכום חסר או אפס" }
            // שורות סיכום ("סה״כ") בסוף קובצי אשראי
            if row.description.contains("סה\"כ") || row.description.contains("סה״כ") { row.error = "שורת סיכום — לא תיובא" }
            result.append(row)
        }
        return result
    }

    /// טביעת אצבע לזיהוי כפילויות: יום + סכום + תיאור מנורמל + חשבון
    public static func fingerprint(date: Date, signedAmount: Money, description: String, accountID: UUID?,
                                   calendar cal: FinanceCalendar = .israel) -> String {
        let c = cal.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)|\(signedAmount.minorUnits)|\(DuplicateDetector.normalize(description))|\(accountID?.uuidString ?? "-")"
    }

    /// מסמן כפילויות מול נתונים קיימים בשיטת "ריבוי": אם בקובץ 2 שורות זהות ובמערכת 1 — תיובא אחת.
    public static func markDuplicates(_ rows: [ImportedRow], existingFingerprints: [String], accountID: UUID?) -> [ImportedRow] {
        var counts: [String: Int] = [:]
        for fp in existingFingerprints { counts[fp, default: 0] += 1 }
        return rows.map { r in
            var r = r
            guard r.isValid, let d = r.date, let a = r.signedAmount else { return r }
            let fp = fingerprint(date: d, signedAmount: a, description: r.description, accountID: accountID)
            if let n = counts[fp], n > 0 { r.isDuplicate = true; counts[fp] = n - 1 }
            return r
        }
    }
}

// MARK: - ייצוא

public enum CSVExporter {
    public struct Row: Sendable {
        public var date: Date; public var kind: String; public var status: String; public var title: String
        public var amount: Money; public var scope: String; public var category: String; public var account: String
        public var paymentMethod: String; public var source: String; public var note: String
        public init(date: Date, kind: String, status: String, title: String, amount: Money, scope: String, category: String,
                    account: String, paymentMethod: String, source: String, note: String) {
            self.date = date; self.kind = kind; self.status = status; self.title = title; self.amount = amount
            self.scope = scope; self.category = category; self.account = account; self.paymentMethod = paymentMethod
            self.source = source; self.note = note
        }
    }

    /// CSV עם BOM כדי ש-Excel יציג עברית נכון
    public static func csv(_ rows: [Row], calendar cal: FinanceCalendar = .israel) -> String {
        var lines = ["תאריך,סוג,סטטוס,תיאור,סכום,אישי/עסקי,קטגוריה,חשבון,אמצעי תשלום,מקור,הערה"]
        for r in rows {
            let c = cal.calendar.dateComponents([.year, .month, .day], from: r.date)
            func pad(_ n: Int?, _ w: Int) -> String { let s = String(n ?? 0); return String(repeating: "0", count: Swift.max(0, w - s.count)) + s }
            let date = "\(pad(c.day, 2))/\(pad(c.month, 2))/\(pad(c.year, 4))"
            let fields = [date, r.kind, r.status, r.title, MoneyFormat.editString(r.amount), r.scope, r.category,
                          r.account, r.paymentMethod, r.source, r.note]
            lines.append(fields.map(CSVParser.escape).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
