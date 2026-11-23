import SwiftUI
import SwiftData
import Charts

struct ReportsView: View {
    @Environment(\.modelContext) private var context
    @Query private var entries: [Entry]
    @Query private var categories: [Category]
    @Query private var accounts: [Account]
    @Query private var rules: [RecurringRule]

    enum Period: String, CaseIterable, Identifiable {
        case month, quarter, year, custom
        var id: String { rawValue }
        var label: String { switch self { case .month: return "חודש"; case .quarter: return "3 חודשים"; case .year: return "שנה"; case .custom: return "טווח" } }
    }

    @State private var period: Period = .month
    @State private var anchor = FinanceCalendar.israel.startOfMonth(.now)
    @State private var customFrom = FinanceCalendar.israel.startOfMonth(.now)
    @State private var customTo = Date.now
    @State private var scopeFilter: Scope?
    @State private var categoryFilter: UUID?
    @State private var shareURL: URL?
    @State private var error: String?

    private let cal = FinanceCalendar.israel

    private var range: Range<Date> {
        switch period {
        case .month: return cal.monthRange(anchor)
        case .quarter: return cal.addMonths(-2, to: anchor)..<cal.endOfMonth(anchor)
        case .year: return cal.addMonths(-11, to: anchor)..<cal.endOfMonth(anchor)
        case .custom:
            let from = cal.startOfDay(min(customFrom, customTo))
            return from..<cal.addDays(1, to: cal.startOfDay(max(customFrom, customTo)))
        }
    }

    private var filtered: [EntrySnapshot] {
        entries.map(\.snapshot).filter { e in
            (scopeFilter == nil || e.scope == scopeFilter) && (categoryFilter == nil || e.categoryID == categoryFilter)
        }
    }

    var body: some View {
        let lookup = NameLookup(categories: categories, accounts: accounts)
        let data = filtered
        let r = range
        let total = BalanceEngine.summary(entries: data, in: r)
        let personal = BalanceEngine.summary(entries: data, in: r, scope: .personal)
        let business = BalanceEngine.summary(entries: data, in: r, scope: .business)
        let byCat = BalanceEngine.expensesByCategory(entries: data, in: r).filter { $0.value.isPositive }.sorted { $0.value > $1.value }
        let fixedVar = fixedVsVariable(data, r)
        let months = monthlySeries(data, endingAt: r.upperBound, count: period == .year ? 12 : 6)
        let byAccount = accountBreakdown(data, r)

        List {
            Section {
                Picker("תקופה", selection: $period) { ForEach(Period.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                if period == .custom {
                    DatePicker("מתאריך", selection: $customFrom, displayedComponents: .date)
                    DatePicker("עד תאריך", selection: $customTo, displayedComponents: .date)
                } else {
                    HStack {
                        Button { anchor = cal.addMonths(-1, to: anchor) } label: { Image(systemName: "chevron.right") }
                        Spacer(); Text(Fmt.monthYear(anchor)).font(.headline); Spacer()
                        Button { anchor = cal.addMonths(1, to: anchor) } label: { Image(systemName: "chevron.left") }
                    }.buttonStyle(.borderless)
                }
                Picker("סיווג", selection: $scopeFilter) {
                    Text("הכול").tag(Scope?.none)
                    ForEach(Scope.allCases) { Text($0.label).tag(Optional($0)) }
                }
                Picker("קטגוריה", selection: $categoryFilter) {
                    Text("כל הקטגוריות").tag(UUID?.none)
                    ForEach(categories.filter { !$0.isArchived }) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if let error { Section { ErrorBanner(message: error) } }

            Section("הכנסות מול הוצאות") {
                row("הכנסות", total.income)
                row("הוצאות נטו", total.netExpenses)
                row("נטו", total.net, colored: true)
                Chart(months, id: \.month) { m in
                    BarMark(x: .value("חודש", Fmt.shortMonth(m.month)), y: .value("סכום", chartValue(m.income)))
                        .foregroundStyle(by: .value("סוג", "הכנסות"))
                        .position(by: .value("סוג", "הכנסות"))
                    BarMark(x: .value("חודש", Fmt.shortMonth(m.month)), y: .value("סכום", chartValue(m.expenses)))
                        .foregroundStyle(by: .value("סוג", "הוצאות"))
                        .position(by: .value("סוג", "הוצאות"))
                }
                .chartForegroundStyleScale(["הכנסות": Theme.income, "הוצאות": Theme.expense])
                .frame(height: 200)
            }

            Section("אישי מול עסקי") {
                LabeledContent("אישי — הוצאות") { MoneyText(money: personal.netExpenses) }
                LabeledContent("עסקי — הכנסות") { MoneyText(money: business.income) }
                LabeledContent("עסקי — הוצאות") { MoneyText(money: business.netExpenses) }
                LabeledContent("רווח עסקי") { MoneyText(money: business.net, colored: true) }
            }

            Section("הוצאות לפי קטגוריה") {
                if byCat.isEmpty { Text("אין הוצאות בתקופה.").foregroundStyle(.secondary) }
                ForEach(byCat, id: \.key) { k, v in
                    HStack {
                        Label(lookup.category(k), systemImage: lookup.symbol(k))
                        Spacer()
                        Text(Fmt.percent(Money.ratioBasisPoints(v, of: total.netExpenses) ?? 0)).font(.caption).foregroundStyle(.secondary)
                        MoneyText(money: v, font: .subheadline.weight(.semibold))
                    }
                }
            }

            Section("קבועות מול משתנות") {
                row("קבועות", fixedVar.0)
                row("משתנות", fixedVar.1)
            }

            Section("לפי חשבון / כרטיס") {
                ForEach(byAccount, id: \.0) { name, money in row(name, money) }
            }

            Section("ייצוא") {
                Button { export(csv: true) } label: { Label("ייצוא תנועות ל-CSV", systemImage: "tablecells") }
                Button { export(csv: false) } label: { Label("יצירת דוח קריא (HTML)", systemImage: "doc.richtext") }
                if let shareURL {
                    ShareLink(item: shareURL) { Label("שיתוף / שמירה: \(shareURL.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
            }
            Section { Text("הדוחות מבוססים על נתונים שהוזנו או יובאו בלבד, ואינם תחליף לייעוץ פיננסי או חשבונאי.").font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("דוחות וניתוח")
    }

    private func row(_ title: String, _ m: Money, colored: Bool = false) -> some View {
        LabeledContent(title) { MoneyText(money: m, font: .body.weight(.semibold), colored: colored) }
    }

    private func chartValue(_ m: Money) -> Double { NSDecimalNumber(decimal: m.decimalValue).doubleValue } // לציור בלבד

    struct MonthPoint { var month: Date; var income: Money; var expenses: Money }

    private func monthlySeries(_ data: [EntrySnapshot], endingAt end: Date, count: Int) -> [MonthPoint] {
        let last = cal.startOfMonth(cal.addDays(-1, to: end))
        return (0..<count).reversed().map { i in
            let m = cal.addMonths(-i, to: last)
            let s = BalanceEngine.summary(entries: data, in: cal.monthRange(m))
            return MonthPoint(month: m, income: s.income, expenses: s.netExpenses)
        }
    }

    private func fixedVsVariable(_ data: [EntrySnapshot], _ r: Range<Date>) -> (Money, Money) {
        var fixed = Money.zero, variable = Money.zero
        for e in data where e.status == .confirmed && e.kind == .expense && r.contains(e.date) {
            if e.isFixed || e.recurringRuleID != nil { fixed += e.amount } else { variable += e.amount }
        }
        return (fixed, variable)
    }

    private func accountBreakdown(_ data: [EntrySnapshot], _ r: Range<Date>) -> [(String, Money)] {
        var totals: [String: Money] = [:]
        for e in data where e.status == .confirmed && e.kind == .expense && r.contains(e.date) {
            let name = e.accountID.flatMap { id in accounts.first { $0.id == id }?.name } ?? "לא משויך"
            totals[name, default: .zero] += e.amount
        }
        return totals.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func export(csv: Bool) {
        let exporter = ReportExporter(context: context)
        do {
            shareURL = csv ? try exporter.exportCSV(range: range)
                           : try exporter.exportHTMLReport(range: range, title: "דוח כספי \(Fmt.date(range.lowerBound)) – \(Fmt.date(cal.addDays(-1, to: range.upperBound)))")
            error = nil
        } catch { self.error = "הייצוא נכשל: \(error.localizedDescription)" }
    }
}
