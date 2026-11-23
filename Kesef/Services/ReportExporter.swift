import Foundation
import SwiftData

/// ייצוא CSV ודוח HTML קריא (נפתח בכל דפדפן וניתן להדפסה ל-PDF מתפריט השיתוף).
@MainActor
struct ReportExporter {
    let context: ModelContext
    var cal = FinanceCalendar.israel

    func exportCSV(range: Range<Date>) throws -> URL {
        let l = Ledger(context: context)
        let cats = Dictionary(uniqueKeysWithValues: l.categories().map { ($0.id, $0.name) })
        let accs = Dictionary(uniqueKeysWithValues: l.accounts(includeArchived: true).map { ($0.id, $0.name) })
        let rows = l.entries().filter { range.contains($0.date) }.sorted { $0.date < $1.date }.map { e in
            CSVExporter.Row(date: e.date, kind: e.kind.label, status: e.status.label(for: e.kind), title: e.title,
                            amount: e.kind == .expense ? -e.amount : e.amount, scope: e.scope.label,
                            category: e.categoryID.flatMap { cats[$0] } ?? "", account: e.accountID.flatMap { accs[$0] } ?? "",
                            paymentMethod: e.paymentMethod?.label ?? "", source: e.source.label, note: e.note)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tnuot-\(cal.monthKey(range.lowerBound)).csv")
        try CSVExporter.csv(rows, calendar: cal).data(using: .utf8)!.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func exportHTMLReport(range: Range<Date>, title: String) throws -> URL {
        let l = Ledger(context: context)
        let entries = l.entries().map(\.snapshot)
        let cats = Dictionary(uniqueKeysWithValues: l.categories().map { ($0.id, $0.name) })
        let total = BalanceEngine.summary(entries: entries, in: range)
        let personal = BalanceEngine.summary(entries: entries, in: range, scope: .personal)
        let business = BalanceEngine.summary(entries: entries, in: range, scope: .business)
        let byCat = BalanceEngine.expensesByCategory(entries: entries, in: range)
            .sorted { $0.value > $1.value }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let m = { (x: Money) in esc(MoneyFormat.string(x)) }
        var html = """
        <!doctype html><html lang="he" dir="rtl"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>\(esc(title))</title>
        <style>body{font-family:-apple-system,Arial,sans-serif;margin:24px;color:#111}h1{font-size:22px}
        table{border-collapse:collapse;width:100%;margin:12px 0}td,th{border-bottom:1px solid #ddd;padding:6px;text-align:right}
        .n{direction:ltr;text-align:left;font-variant-numeric:tabular-nums}.muted{color:#666;font-size:12px}</style></head><body>
        <h1>\(esc(title))</h1>
        <p class="muted">הדוח מבוסס על נתונים שהוזנו או יובאו לאפליקציה בלבד. אינו תחליף לייעוץ פיננסי או חשבונאי.</p>
        <table><tr><th></th><th>הכנסות</th><th>הוצאות נטו</th><th>נטו</th></tr>
        <tr><td>סה״כ</td><td class="n">\(m(total.income))</td><td class="n">\(m(total.netExpenses))</td><td class="n">\(m(total.net))</td></tr>
        <tr><td>אישי</td><td class="n">\(m(personal.income))</td><td class="n">\(m(personal.netExpenses))</td><td class="n">\(m(personal.net))</td></tr>
        <tr><td>עסקי</td><td class="n">\(m(business.income))</td><td class="n">\(m(business.netExpenses))</td><td class="n">\(m(business.net))</td></tr>
        </table><h2>הוצאות לפי קטגוריה</h2><table><tr><th>קטגוריה</th><th>סכום</th></tr>
        """
        for (k, v) in byCat {
            html += "<tr><td>\(esc(k.flatMap { cats[$0] } ?? "ללא קטגוריה"))</td><td class=\"n\">\(m(v))</td></tr>"
        }
        html += "</table><h2>תנועות</h2><table><tr><th>תאריך</th><th>תיאור</th><th>סוג</th><th>סכום</th></tr>"
        let f = DateFormatter(); f.locale = Locale(identifier: "he_IL"); f.calendar = cal.calendar; f.timeZone = cal.calendar.timeZone
        f.dateFormat = "dd/MM/yyyy"
        for e in l.entries().filter({ range.contains($0.date) && $0.status == .confirmed }).sorted(by: { $0.date < $1.date }) {
            html += "<tr><td>\(f.string(from: e.date))</td><td>\(esc(e.title))</td><td>\(e.kind.label) · \(e.scope.label)</td><td class=\"n\">\(m(e.kind == .expense ? -e.amount : e.amount))</td></tr>"
        }
        html += "</table></body></html>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("doch-\(cal.monthKey(range.lowerBound)).html")
        try html.data(using: .utf8)!.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
