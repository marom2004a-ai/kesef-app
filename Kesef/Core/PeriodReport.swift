import Foundation

/// שורה בדוח התקופתי של העסק (הכנסה או הוצאה)
public struct PeriodReportLine: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var kind: EntryKind
    public var categoryID: UUID?
    /// סכום כולל מע״מ. בזיכוי על הוצאה — שלילי
    public var gross: Money
    /// מע״מ: בהכנסות — מע״מ עסקאות; בהוצאות — מע״מ התשומות המוכר
    public var vat: Money
    public var hasReceipt: Bool
    public var net: Money { gross - vat }
}

/// דוח הכנסות והוצאות של העסק לתקופת דיווח (חודשי / דו-חודשי)
public struct PeriodReport: Hashable, Sendable {
    public var period: Range<Date>
    public var income: [PeriodReportLine] = []
    public var expenses: [PeriodReportLine] = []

    public var incomeGross: Money { income.map(\.gross).sum() }
    public var incomeVAT: Money { income.map(\.vat).sum() }
    public var incomeNet: Money { incomeGross - incomeVAT }
    public var expensesGross: Money { expenses.map(\.gross).sum() }
    public var expensesVAT: Money { expenses.map(\.vat).sum() }
    public var expensesNet: Money { expensesGross - expensesVAT }
    /// הוצאות (לא זיכויים) שאין להן צילום קבלה
    public var expensesMissingReceipt: Int { expenses.filter { $0.kind == .expense && !$0.hasReceipt }.count }
}

public enum PeriodReportEngine {

    /// בונה את הדוח מאותם כללים של דוח המע״מ: רק תנועות עסקיות מאושרות בתקופה.
    public static func build(entries: [EntrySnapshot], withReceipt: Set<UUID> = [], period p: Range<Date>,
                             settings: VatSettings, deductibleBP: [UUID: Int] = [:]) -> PeriodReport {
        var r = PeriodReport(period: p)
        let rate = settings.isRegistered ? settings.rateBasisPoints : 0
        for e in entries where e.status == .confirmed && e.scope == .business && p.contains(e.date) {
            let fullVAT = settings.isRegistered ? (e.vatOverride ?? VatEngine.vatIncluded(in: e.amount, rateBasisPoints: rate)) : .zero
            switch e.kind {
            case .income:
                r.income.append(PeriodReportLine(id: e.id, date: e.date, title: e.title, kind: e.kind, categoryID: e.categoryID,
                                                 gross: e.amount, vat: fullVAT, hasReceipt: withReceipt.contains(e.id)))
            case .expense, .refund:
                let sign: Int64 = e.kind == .expense ? 1 : -1
                let bp = e.categoryID.flatMap { deductibleBP[$0] } ?? 10_000
                r.expenses.append(PeriodReportLine(id: e.id, date: e.date, title: e.title, kind: e.kind, categoryID: e.categoryID,
                                                   gross: Money(minorUnits: sign * e.amount.minorUnits),
                                                   vat: Money(minorUnits: sign * fullVAT.multiplied(byBasisPoints: bp).minorUnits),
                                                   hasReceipt: withReceipt.contains(e.id)))
            default:
                break
            }
        }
        r.income.sort { $0.date < $1.date }
        r.expenses.sort { $0.date < $1.date }
        return r
    }

    /// קובץ CSV לרואה החשבון (עם BOM כדי שאקסל יציג עברית)
    public static func csv(_ r: PeriodReport, categoryNames: [UUID: String] = [:], calendar cal: FinanceCalendar = .israel) -> String {
        func pad(_ n: Int?, _ w: Int) -> String { let s = String(n ?? 0); return String(repeating: "0", count: Swift.max(0, w - s.count)) + s }
        func date(_ d: Date) -> String {
            let c = cal.calendar.dateComponents([.year, .month, .day], from: d)
            return "\(pad(c.day, 2))/\(pad(c.month, 2))/\(pad(c.year, 4))"
        }
        let m = MoneyFormat.editString
        var lines = ["סוג,תאריך,תיאור,קטגוריה,סכום כולל מע״מ,מע״מ,לפני מע״מ,צילום קבלה"]
        func add(_ l: PeriodReportLine, _ type: String) {
            let fields = [type, date(l.date), l.title, l.categoryID.flatMap { categoryNames[$0] } ?? "",
                          m(l.gross), m(l.vat), m(l.net), l.hasReceipt ? "יש" : "אין"]
            lines.append(fields.map(CSVParser.escape).joined(separator: ","))
        }
        for l in r.income { add(l, "הכנסה") }
        for l in r.expenses { add(l, l.kind == .refund ? "זיכוי על הוצאה" : "הוצאה") }
        lines.append("")
        lines.append(["סיכום", "", "סה״כ הכנסות", "", m(r.incomeGross), m(r.incomeVAT), m(r.incomeNet), ""].joined(separator: ","))
        lines.append(["סיכום", "", "סה״כ הוצאות", "", m(r.expensesGross), m(r.expensesVAT), m(r.expensesNet), ""].joined(separator: ","))
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
