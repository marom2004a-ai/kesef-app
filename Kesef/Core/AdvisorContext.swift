import Foundation

/// בונה סיכום טקסט קומפקטי של הנתונים הפיננסיים ליועצת ה-AI.
/// לא נכללים: מספרי כרטיס, שמות חשבונות, הערות חופשיות. רק סכומים, תאריכים, קטגוריות ושמות בתי עסק.
public struct AdvisorContextInput: Sendable {
    public var now: Date
    public var entries: [EntrySnapshot]
    public var categories: [CategorySnapshot]
    public var recurring: [RecurringSnapshot]
    public var budgets: [BudgetSnapshot]
    public var accounts: [AccountSnapshot]
    public var partner: PartnerSettings?
    public var vat: VatSettings?
    public var vatDeductibleBP: [UUID: Int]
    public var monthlySavingsTarget: Money
    public var reserve: Money
    public var goals: [(title: String, target: Money, saved: Money)]

    public init(now: Date, entries: [EntrySnapshot], categories: [CategorySnapshot], recurring: [RecurringSnapshot],
                budgets: [BudgetSnapshot], accounts: [AccountSnapshot], partner: PartnerSettings?, vat: VatSettings?,
                vatDeductibleBP: [UUID: Int] = [:], monthlySavingsTarget: Money = .zero, reserve: Money = .zero,
                goals: [(title: String, target: Money, saved: Money)] = []) {
        self.now = now; self.entries = entries; self.categories = categories; self.recurring = recurring
        self.budgets = budgets; self.accounts = accounts; self.partner = partner; self.vat = vat
        self.vatDeductibleBP = vatDeductibleBP; self.monthlySavingsTarget = monthlySavingsTarget
        self.reserve = reserve; self.goals = goals
    }
}

public enum AdvisorContext {
    /// מקסימום תנועות מפורטות שנשלחות (מהחדשות לישנות)
    public static let maxDetailedEntries = 250

    public static func build(_ input: AdvisorContextInput, calendar cal: FinanceCalendar = .israel) -> String {
        let m = { (x: Money) in MoneyFormat.editString(x) + " ₪" }
        let names = Dictionary(uniqueKeysWithValues: input.categories.map { ($0.id, $0.name) })
        let catName = { (id: UUID?) in id.flatMap { names[$0] } ?? "ללא קטגוריה" }
        func day(_ d: Date) -> String {
            let c = cal.calendar.dateComponents([.year, .month, .day], from: d)
            return "\(c.day ?? 0)/\(c.month ?? 0)/\(c.year ?? 0)"
        }
        var out: [String] = []
        out.append("תאריך היום: \(day(input.now)). כל הסכומים בשקלים. סכומים עסקיים כוללים מע״מ.")

        // מצב נוכחי
        let dash = DashboardEngine.build(now: input.now, accounts: input.accounts, entries: input.entries, recurring: input.recurring,
                                         partner: input.partner, monthlySavingsTarget: input.monthlySavingsTarget,
                                         reserve: input.reserve, vat: input.vat, vatDeductibleBP: input.vatDeductibleBP, calendar: cal)
        out.append("""
        ## מצב נוכחי
        יתרה נזילה: \(m(dash.currentBalance)) | חוב באשראי: \(m(dash.creditCardDebt)) | חיסכון: \(m(dash.savings))
        החודש: הכנסות \(m(dash.monthIncome)), הוצאות נטו \(m(dash.monthExpenses)), הכנסות צפויות \(m(dash.expectedIncome)), הוצאות עתידיות \(m(dash.upcomingExpenses))
        תחזית סוף חודש: בסיסי \(m(dash.forecastEndOfMonth)), שמרני \(m(dash.forecastEndOfMonthConservative)). סכום פנוי לשימוש: \(m(dash.safeToSpend))
        כרית ביטחון שהוגדרה: \(m(input.reserve)). יעד חיסכון חודשי: \(m(input.monthlySavingsTarget)). עסקאות ממתינות לאישור: \(dash.pendingReviewCount)
        """)
        if !dash.warnings.isEmpty { out.append("אזהרות: " + dash.warnings.joined(separator: " ")) }

        // היסטוריה חודשית
        let analysis = IncomeAnalyzer.analyze(entries: input.entries, recurring: input.recurring, now: input.now, calendar: cal)
        if !analysis.months.isEmpty {
            var lines = ["## חודשים (הכנסות / הוצאות נטו / נטו)"]
            for mo in analysis.months {
                let c = cal.calendar.dateComponents([.year, .month], from: mo.monthStart)
                lines.append("\(c.month ?? 0)/\(c.year ?? 0)\(mo.isComplete ? "" : " (חלקי)"): \(m(mo.income)) / \(m(mo.netExpenses)) / \(m(mo.net))\(mo.strength.map { " — \($0.label)" } ?? "")")
            }
            lines.append("ממוצע הכנסות: 3 ח׳ \(analysis.average3.map(m) ?? "אין מספיק נתונים"), 6 ח׳ \(analysis.average6.map(m) ?? "אין מספיק נתונים"). קבועות בחודש: \(m(analysis.fixedMonthly))")
            out.append(lines.joined(separator: "\n"))
        }

        // קטגוריות — 3 חודשים אחרונים + החודש
        var catLines = ["## הוצאות לפי קטגוריה (אישי/עסקי)"]
        let monthsBack = cal.completeMonths(before: input.now, count: 3) + [cal.startOfMonth(input.now)]
        let scopeOf = Dictionary(uniqueKeysWithValues: input.categories.map { ($0.id, $0) })
        for mo in monthsBack {
            let byCat = BalanceEngine.expensesByCategory(entries: input.entries, in: cal.monthRange(mo))
                .filter { $0.value.isPositive }.sorted { $0.value > $1.value }
            guard !byCat.isEmpty else { continue }
            let c = cal.calendar.dateComponents([.year, .month], from: mo)
            let parts = byCat.prefix(14).map { k, v -> String in
                let cat = k.flatMap { scopeOf[$0] }
                let tag = cat.map { ($0.scope == .business ? "ע" : "א") + ($0.isEssential ? "" : ",לא חיוני") } ?? "?"
                return "\(catName(k)) [\(tag)] \(m(v))"
            }
            catLines.append("\(c.month ?? 0)/\(c.year ?? 0): " + parts.joined(separator: "; "))
        }
        if catLines.count > 1 { out.append(catLines.joined(separator: "\n")) }

        // בתי עסק חוזרים — 90 יום
        let since = cal.addDays(-90, to: cal.startOfDay(input.now))
        var merchants: [String: (count: Int, total: Money, scope: Scope)] = [:]
        for e in input.entries where e.status == .confirmed && e.kind == .expense && e.date >= since {
            let key = e.title.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var cur = merchants[key] ?? (0, .zero, e.scope)
            cur.count += 1; cur.total += e.amount
            merchants[key] = cur
        }
        let topMerchants = merchants.sorted { $0.value.total > $1.value.total }.prefix(25)
        if !topMerchants.isEmpty {
            out.append("## בתי עסק מובילים ב-90 יום (פעמים, סה״כ)\n" + topMerchants.map {
                "\($0.key) [\($0.value.scope == .business ? "עסקי" : "אישי")]: \($0.value.count) פעמים, \(m($0.value.total))"
            }.joined(separator: "\n"))
        }

        // חיובים קבועים
        let active = input.recurring.filter { !$0.isPaused }
        if !active.isEmpty {
            out.append("## חיובים/הכנסות קבועים\n" + active.map {
                "\($0.title) [\($0.scope.label), \(catName($0.categoryID))]: \(m($0.amount)) \($0.frequency.label)\($0.isVariableAmount ? " (משוער)" : "") = \(m($0.monthlyEquivalent)) בחודש\($0.kind == .income ? " (הכנסה)" : "")"
            }.joined(separator: "\n"))
        }

        // תקציבים
        let st = BudgetEngine.status(budgets: input.budgets, entries: input.entries, month: input.now, now: input.now, calendar: cal)
        if !st.isEmpty {
            out.append("## תקציבים החודש\n" + st.map {
                "\(catName($0.categoryID)): נוצל \(m($0.used)) מתוך \(m($0.limit)) (\($0.usedBasisPoints / 100)%)\($0.projected.map { " צפי \(m($0))" } ?? "") — \($0.level.label)"
            }.joined(separator: "\n"))
        }

        // מע״מ ושותף
        if let vat = input.vat, vat.isRegistered {
            let p = VatEngine.period(containing: input.now, settings: vat, calendar: cal)
            let s = VatEngine.statement(entries: input.entries, period: p, settings: vat, deductibleBP: input.vatDeductibleBP, calendar: cal)
            out.append("## מע״מ (עוסק מורשה, \(vat.rateBasisPoints / 100)%) תקופה נוכחית: מע״מ עסקאות \(m(s.outputVAT)), תשומות \(m(s.inputVAT)), לתשלום \(m(s.vatPayable)) עד \(day(s.dueDate)). רווח עסקי לפני מס \(m(s.profitBeforeTax)).")
            if let partner = input.partner, partner.isActive {
                let sp = PartnerEngine.split(entries: input.entries, period: p, partner: partner, vat: vat, deductibleBP: input.vatDeductibleBP, calendar: cal)
                out.append("שותף \(partner.name) \(partner.shareBasisPoints / 100)%: חלקו \(m(sp.partnerShare)), שולם לו \(m(sp.paidToPartner)), נותר \(m(sp.stillOwedToPartner)). החלק שלי \(m(sp.myShare)).")
            }
        }

        if !input.goals.isEmpty {
            out.append("## יעדי חיסכון\n" + input.goals.map { "\($0.title): \(m($0.saved)) מתוך \(m($0.target))" }.joined(separator: "\n"))
        }

        // המלצות כלליות שהמערכת כבר חישבה
        let recs = SavingsAdvisor.recommendations(AdvisorInput(now: input.now, entries: input.entries, recurring: input.recurring,
                                                              categories: input.categories, accounts: input.accounts), calendar: cal)
        if !recs.isEmpty {
            out.append("## תובנות שהמערכת חישבה לפי כללים\n" + recs.map { "- \($0.title): \($0.detail.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n"))
        }

        // תנועות מפורטות אחרונות
        let detailed = input.entries.filter { $0.status != .cancelled && $0.kind.isProfitAndLoss }
            .sorted { $0.date > $1.date }.prefix(maxDetailedEntries)
        if !detailed.isEmpty {
            out.append("## תנועות אחרונות (תאריך | סוג | סטטוס | תיאור | קטגוריה | סכום)\n" + detailed.map {
                "\(day($0.date)) | \($0.kind.label) \($0.scope.label) | \($0.status.label(for: $0.kind)) | \($0.title) | \(catName($0.categoryID)) | \(m($0.amount))"
            }.joined(separator: "\n"))
        }
        return out.joined(separator: "\n\n")
    }
}
