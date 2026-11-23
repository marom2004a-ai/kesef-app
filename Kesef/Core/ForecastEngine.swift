import Foundation

public enum ForecastEventKind: String, Sendable, Hashable {
    case expectedIncome, recurringIncome, plannedExpense, pendingExpense, recurringExpense,
         cardPayment, partnerShare, savingsTarget, variableSpending

    public var label: String {
        switch self {
        case .expectedIncome: return "הכנסה צפויה"
        case .recurringIncome: return "הכנסה קבועה"
        case .plannedExpense: return "הוצאה מתוכננת"
        case .pendingExpense: return "רכישה ממתינה לאישור"
        case .recurringExpense: return "חיוב קבוע"
        case .cardPayment: return "חיוב כרטיס אשראי"
        case .partnerShare: return "חלק השותף"
        case .savingsTarget: return "העברה ליעד חיסכון"
        case .variableSpending: return "הוצאות שוטפות (הערכה)"
        }
    }
    public var isOutflowCommitment: Bool {
        switch self {
        case .plannedExpense, .pendingExpense, .recurringExpense, .cardPayment, .partnerShare: return true
        default: return false
        }
    }
}

public struct ForecastEvent: Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    /// חיובי = נכנס, שלילי = יוצא
    public var amount: Money
    public var title: String
    public var kind: ForecastEventKind
}

public struct ForecastPoint: Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var balance: Money
}

public struct ForecastResult: Sendable {
    public var scenario: Scenario
    public var startBalance: Money
    public var points: [ForecastPoint]
    public var events: [ForecastEvent]
    public var endBalance: Money
    public var minBalance: Money
    public var minBalanceDate: Date
    public var firstNegativeDate: Date?
    public var assumptions: [String]
}

public struct ForecastInput: Sendable {
    public var now: Date
    /// גבול עליון לא כולל
    public var horizonEnd: Date
    public var accounts: [AccountSnapshot]
    public var entries: [EntrySnapshot]
    public var recurring: [RecurringSnapshot]
    public var partner: PartnerSettings?
    public var monthlySavingsTarget: Money
    public var includeVariableSpending: Bool

    public init(now: Date, horizonEnd: Date, accounts: [AccountSnapshot], entries: [EntrySnapshot],
                recurring: [RecurringSnapshot], partner: PartnerSettings? = nil,
                monthlySavingsTarget: Money = .zero, includeVariableSpending: Bool = true) {
        self.now = now; self.horizonEnd = horizonEnd; self.accounts = accounts; self.entries = entries
        self.recurring = recurring; self.partner = partner; self.monthlySavingsTarget = monthlySavingsTarget
        self.includeVariableSpending = includeVariableSpending
    }
}

/// מנוע תחזית תזרים יומית. כל הנחה נרשמת ב-assumptions כדי שהתחזית תהיה ניתנת להסבר.
public enum ForecastEngine {

    public static func run(_ input: ForecastInput, scenario: Scenario, calendar cal: FinanceCalendar = .israel) -> ForecastResult {
        let today = cal.startOfDay(input.now)
        let end = input.horizonEnd
        var assumptions: [String] = []
        var events: [ForecastEvent] = []
        let accountsByID = Dictionary(uniqueKeysWithValues: input.accounts.map { ($0.id, $0) })

        let start = BalanceEngine.liquidTotal(accounts: input.accounts, entries: input.entries)

        // חיוב שבוצע בכרטיס יורד מהבנק רק ביום החיוב של הכרטיס
        func cashDate(for date: Date, accountID: UUID?) -> Date {
            let d = Swift.max(cal.startOfDay(date), today)
            guard let id = accountID, let acc = accountsByID[id], acc.kind == .creditCard else { return d }
            guard let billing = acc.billingDay else { return d }
            return cal.nextBillingDate(onOrAfter: cal.addDays(1, to: d), billingDay: billing)
        }
        func affectsLiquid(_ accountID: UUID?) -> Bool {
            guard let id = accountID, let acc = accountsByID[id] else { return true }
            return acc.kind.isLiquid || acc.kind == .creditCard
        }

        // 1. הכנסות צפויות
        for e in input.entries where e.kind == .income && e.status == .planned {
            guard affectsLiquid(e.accountID) else { continue }
            let overdue = cal.startOfDay(e.date) < today
            let certainty: Certainty = overdue ? .low : e.certainty
            guard scenario.includes(certainty) else { continue }
            let d = Swift.max(cal.startOfDay(e.date), today)
            if d < end {
                events.append(ForecastEvent(date: d, amount: e.amount, title: e.title, kind: .expectedIncome))
            }
        }

        // 2. הוצאות מתוכננות ורכישות שממתינות לאישור (הכסף כבר יצא או ייצא)
        for e in input.entries where e.kind == .expense && (e.status == .planned || e.status == .pendingReview) {
            guard affectsLiquid(e.accountID) else { continue }
            let d = cashDate(for: e.date, accountID: e.accountID)
            if d < end {
                events.append(ForecastEvent(date: d, amount: -e.amount, title: e.title,
                                            kind: e.status == .pendingReview ? .pendingExpense : .plannedExpense))
            }
        }

        // 3. חיובים והכנסות קבועים שעוד לא נרשמו
        let monthStart = cal.startOfMonth(today)
        for r in input.recurring where !r.isPaused {
            guard affectsLiquid(r.accountID) else { continue }
            // מועדים שעברו החודש ולא נרשמו — רק בתרחיש השמרני (ייתכן שכבר ירדו ולא נרשמו)
            let from = scenario == .conservative ? monthStart : today
            for occ in RecurrenceEngine.occurrences(of: r, from: from, to: end, calendar: cal) {
                if RecurrenceEngine.isRecorded(rule: r.id, occurrence: occ, entries: input.entries, calendar: cal) { continue }
                if r.kind == .income {
                    guard scenario.includes(.medium), occ >= today else { continue }
                    events.append(ForecastEvent(date: occ, amount: r.amount, title: r.title, kind: .recurringIncome))
                } else {
                    let d = cashDate(for: occ, accountID: r.accountID)
                    if d < end {
                        events.append(ForecastEvent(date: d, amount: -r.amount, title: r.title, kind: .recurringExpense))
                    }
                }
            }
        }
        if input.recurring.contains(where: { $0.isVariableAmount && !$0.isPaused }) {
            assumptions.append("חיובים קבועים בסכום משתנה מחושבים לפי הסכום המשוער שהוגדר.")
        }

        // 4. סילוק חוב קיים בכרטיסי אשראי ביום החיוב הבא
        for acc in input.accounts where acc.kind == .creditCard && acc.includeInTotals {
            let bal = BalanceEngine.balance(of: acc, entries: input.entries)
            guard bal.isNegative else { continue }
            let d: Date
            if let billing = acc.billingDay {
                d = cal.nextBillingDate(onOrAfter: today, billingDay: billing)
            } else {
                d = today
                assumptions.append("לכרטיס \(acc.name) לא הוגדר יום חיוב — החוב נלקח בחשבון כבר היום.")
            }
            if d < end {
                events.append(ForecastEvent(date: d, amount: bal, title: acc.name, kind: .cardPayment))
            }
        }
        if input.accounts.contains(where: { $0.kind == .creditCard }) {
            assumptions.append("כל יתרת החוב בכרטיס האשראי נחשבת כיורדת ביום החיוב הקרוב.")
        }

        // 5. חלק השותף לחודש הנוכחי — בסוף החודש
        let lastDayOfMonth = cal.addDays(-1, to: cal.endOfMonth(today))
        if let partner = input.partner, partner.isActive, lastDayOfMonth < end {
            let st = PartnerEngine.statement(entries: input.entries, period: cal.monthRange(today), settings: partner)
            var owed = st.owed
            // חלק השותף גם מהכנסות עסקיות צפויות שנכללו בתרחיש החודש
            let expectedBusiness = input.entries.filter {
                $0.kind == .income && $0.status == .planned && $0.scope == .business
                    && cal.monthRange(today).contains(Swift.max(cal.startOfDay($0.date), today))
                    && scenario.includes(cal.startOfDay($0.date) < today ? .low : $0.certainty)
            }.map(\.amount).sum()
            owed += expectedBusiness.multiplied(byBasisPoints: partner.shareBasisPoints)
            if owed.isPositive {
                events.append(ForecastEvent(date: lastDayOfMonth, amount: -owed, title: partner.name, kind: .partnerShare))
                assumptions.append("חלק השותף (\(partner.shareBasisPoints / 100)%) מחושב גם מהכנסות עסקיות צפויות, ומשולם בסוף החודש.")
            }
        }

        // 6. יעד חיסכון חודשי — מה שנותר להעביר החודש
        if input.monthlySavingsTarget.isPositive, lastDayOfMonth < end {
            let savingsIDs = Set(input.accounts.filter { $0.kind == .savings }.map(\.id))
            let transferred = input.entries.filter {
                $0.status == .confirmed && $0.kind == .transfer && cal.monthRange(today).contains($0.date)
                    && $0.toAccountID.map { savingsIDs.contains($0) } == true
            }.map(\.amount).sum()
            let remaining = input.monthlySavingsTarget - transferred
            if remaining.isPositive {
                events.append(ForecastEvent(date: lastDayOfMonth, amount: -remaining, title: "יעד חיסכון חודשי", kind: .savingsTarget))
            }
        }

        // 7. הוצאות שוטפות משתנות — ממוצע יומי היסטורי
        if input.includeVariableSpending {
            if let daily = averageDailyVariableSpend(entries: input.entries, now: input.now, calendar: cal) {
                let perDay = daily.multiplied(byBasisPoints: scenario.variableSpendingPercent * 100)
                var d = cal.addDays(1, to: today)
                while d < end {
                    events.append(ForecastEvent(date: d, amount: -perDay, title: "הוצאות שוטפות", kind: .variableSpending))
                    d = cal.addDays(1, to: d)
                }
                assumptions.append("הוצאות שוטפות: \(MoneyFormat.string(perDay)) ליום (ממוצע 90 הימים האחרונים × \(scenario.variableSpendingPercent)%).")
            } else {
                assumptions.append("אין עדיין 30 ימים של הוצאות — התחזית לא כוללת הוצאות שוטפות לא מתוכננות.")
            }
        }

        switch scenario {
        case .conservative: assumptions.insert("נכללות רק הכנסות צפויות ודאיות. הכנסות שעבר מועדן אינן נכללות.", at: 0)
        case .base: assumptions.insert("נכללות הכנסות צפויות ודאיות וסבירות.", at: 0)
        case .optimistic: assumptions.insert("נכללות כל ההכנסות הצפויות, גם לא בטוחות.", at: 0)
        }

        // בניית קו יומי
        events.sort { $0.date < $1.date }
        var points: [ForecastPoint] = []
        var balance = start
        var minBal = start
        var minDate = today
        var firstNegative: Date? = start.isNegative ? today : nil
        var idx = 0
        var day = today
        while day < end {
            let next = cal.addDays(1, to: day)
            while idx < events.count && events[idx].date < next {
                balance += events[idx].amount
                idx += 1
            }
            points.append(ForecastPoint(date: day, balance: balance))
            if balance < minBal { minBal = balance; minDate = day }
            if balance.isNegative && firstNegative == nil { firstNegative = day }
            day = next
        }

        return ForecastResult(scenario: scenario, startBalance: start, points: points, events: events,
                              endBalance: balance, minBalance: minBal, minBalanceDate: minDate,
                              firstNegativeDate: firstNegative, assumptions: assumptions)
    }

    /// ממוצע יומי של הוצאות משתנות (לא קבועות) ב-90 הימים האחרונים. nil אם יש פחות מ-30 ימי היסטוריה.
    public static func averageDailyVariableSpend(entries: [EntrySnapshot], now: Date, lookbackDays: Int = 90,
                                                 calendar cal: FinanceCalendar = .israel) -> Money? {
        let today = cal.startOfDay(now)
        let confirmed = entries.filter { $0.status == .confirmed && ($0.kind == .expense || $0.kind == .refund) }
        guard let first = confirmed.map(\.date).min() else { return nil }
        let historyDays = cal.daysBetween(first, today)
        guard historyDays >= 30 else { return nil }
        let days = Swift.min(lookbackDays, historyDays)
        let from = cal.addDays(-days, to: today)
        var total = Money.zero
        for e in confirmed where e.date >= from && e.date < today && !e.isFixed && e.recurringRuleID == nil {
            total += e.kind == .expense ? e.amount : -e.amount
        }
        guard total.isPositive else { return .zero }
        return Money(minorUnits: Money.roundedDivide(total.minorUnits, by: Int64(days)))
    }
}

// MARK: - לוח בקרה

public struct DashboardSnapshot: Sendable {
    public var currentBalance: Money
    public var lastBalanceUpdate: Date?
    public var creditCardDebt: Money
    public var savings: Money
    public var monthIncome: Money
    public var monthExpenses: Money
    public var upcomingExpenses: Money
    public var expectedIncome: Money
    public var forecastEndOfMonth: Money
    public var forecastEndOfMonthConservative: Money
    public var safeToSpend: Money
    public var pendingReviewCount: Int
    public var partnerOwed: Money?
    public var warnings: [String]
}

public enum DashboardEngine {
    public static func build(now: Date, accounts: [AccountSnapshot], entries: [EntrySnapshot], recurring: [RecurringSnapshot],
                             partner: PartnerSettings?, monthlySavingsTarget: Money, reserve: Money,
                             calendar cal: FinanceCalendar = .israel) -> DashboardSnapshot {
        let month = cal.monthRange(now)
        let summary = BalanceEngine.summary(entries: entries, in: month)
        let input = ForecastInput(now: now, horizonEnd: month.upperBound, accounts: accounts, entries: entries,
                                  recurring: recurring, partner: partner, monthlySavingsTarget: monthlySavingsTarget,
                                  includeVariableSpending: false)
        let base = ForecastEngine.run(input, scenario: .base, calendar: cal)
        let conservative = ForecastEngine.run(input, scenario: .conservative, calendar: cal)
        let optimistic = ForecastEngine.run(input, scenario: .optimistic, calendar: cal)

        let upcoming = base.events.filter { $0.kind.isOutflowCommitment }.map(\.amount).sum().absolute
        let expected = optimistic.events.filter { $0.kind == .expectedIncome || $0.kind == .recurringIncome }.map(\.amount).sum()

        // סכום פנוי: היתרה הנמוכה ביותר עד סוף החודש בתרחיש שמרני (אחרי התחייבויות ויעד חיסכון), פחות כרית ביטחון
        var safe = conservative.minBalance - reserve
        if safe.isNegative { safe = .zero }

        var warnings: [String] = []
        if let neg = conservative.firstNegativeDate {
            let f = DateFormatter()
            f.calendar = cal.calendar; f.locale = Locale(identifier: "he_IL"); f.timeZone = cal.calendar.timeZone
            f.dateFormat = "d בMMMM"
            warnings.append("בתרחיש השמרני היתרה עלולה לרדת מתחת לאפס ב-\(f.string(from: neg)).")
        }
        let last = BalanceEngine.lastBalanceUpdate(accounts: accounts)
        if let last, cal.daysBetween(last, now) > 7 {
            warnings.append("יתרות החשבונות עודכנו לפני \(cal.daysBetween(last, now)) ימים — כדאי לעדכן מול הבנק.")
        }
        let pending = entries.filter { $0.status == .pendingReview }.count

        var owed: Money? = nil
        if let partner, partner.isActive {
            owed = PartnerEngine.statement(entries: entries, period: month, settings: partner).owed
        }

        return DashboardSnapshot(currentBalance: base.startBalance, lastBalanceUpdate: last,
                                 creditCardDebt: BalanceEngine.creditCardDebt(accounts: accounts, entries: entries),
                                 savings: BalanceEngine.savingsTotal(accounts: accounts, entries: entries),
                                 monthIncome: summary.income, monthExpenses: summary.netExpenses,
                                 upcomingExpenses: upcoming, expectedIncome: expected,
                                 forecastEndOfMonth: base.endBalance, forecastEndOfMonthConservative: conservative.endBalance,
                                 safeToSpend: safe, pendingReviewCount: pending, partnerOwed: owed, warnings: warnings)
    }
}
