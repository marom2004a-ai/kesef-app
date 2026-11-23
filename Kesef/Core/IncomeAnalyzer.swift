import Foundation

public enum MonthStrength: String, Sendable {
    case weak, normal, strong
    public var label: String {
        switch self {
        case .weak: return "חודש חלש"
        case .normal: return "חודש רגיל"
        case .strong: return "חודש חזק"
        }
    }
}

public struct MonthFigures: Sendable, Identifiable {
    public var id: Date { monthStart }
    public var monthStart: Date
    public var income: Money
    public var businessIncome: Money
    public var netExpenses: Money
    public var isComplete: Bool
    public var strength: MonthStrength?
    public var net: Money { income - netExpenses }
}

public struct IncomeAnalysis: Sendable {
    /// 12 חודשים שלמים אחרונים + החודש הנוכחי, מהישן לחדש. רק חודשים שיש בהם נתונים או אחרי תחילת הנתונים.
    public var months: [MonthFigures]
    public var average3: Money?
    public var average6: Money?
    public var average12: Money?
    public var completeMonthsWithData: Int
    /// חיובים קבועים בשווי חודשי
    public var fixedMonthly: Money
    /// אחוז הקבועות מתוך ממוצע ההכנסות (נקודות בסיס)
    public var fixedToIncomeBasisPoints: Int?
    public var weakest: MonthFigures?
    public var strongest: MonthFigures?
}

public enum IncomeAnalyzer {
    public static func analyze(entries: [EntrySnapshot], recurring: [RecurringSnapshot], now: Date,
                               calendar cal: FinanceCalendar = .israel) -> IncomeAnalysis {
        let firstData = entries.filter { $0.status == .confirmed }.map(\.date).min()
        let currentMonth = cal.startOfMonth(now)
        var months: [MonthFigures] = []
        for m in cal.completeMonths(before: now, count: 12) + [currentMonth] {
            guard let firstData, cal.endOfMonth(m) > firstData else { continue }
            let s = BalanceEngine.summary(entries: entries, in: cal.monthRange(m))
            let b = BalanceEngine.summary(entries: entries, in: cal.monthRange(m), scope: .business)
            // חודש נחשב שלם אם הסתיים וגם הנתונים התחילו לפני תחילתו
            let complete = m < currentMonth && firstData <= cal.addDays(3, to: m)
            months.append(MonthFigures(monthStart: m, income: s.income, businessIncome: b.income,
                                       netExpenses: s.netExpenses, isComplete: complete, strength: nil))
        }
        let complete = months.filter(\.isComplete)

        func avg(_ n: Int) -> Money? {
            guard complete.count >= n else { return nil }
            let slice = complete.suffix(n)
            return Money(minorUnits: Money.roundedDivide(slice.map(\.income).sum().minorUnits, by: Int64(n)))
        }
        let a3 = avg(3), a6 = avg(6), a12 = avg(12)

        // סיווג חלש/רגיל/חזק מול ממוצע כל החודשים השלמים (לפחות 3)
        if complete.count >= 3 {
            let reference = Money(minorUnits: Money.roundedDivide(complete.map(\.income).sum().minorUnits, by: Int64(complete.count)))
            for i in months.indices where months[i].isComplete {
                let bp = Money.ratioBasisPoints(months[i].income, of: reference) ?? 10_000
                months[i].strength = bp < 8_500 ? .weak : (bp > 11_500 ? .strong : .normal)
            }
        }

        let fixed = recurring.filter { !$0.isPaused && $0.kind == .expense }.map(\.monthlyEquivalent).sum()
        let reference = a6 ?? a3
        let ratio = reference.flatMap { Money.ratioBasisPoints(fixed, of: $0) }
        let completeAfter = months.filter(\.isComplete)
        return IncomeAnalysis(months: months, average3: a3, average6: a6, average12: a12,
                              completeMonthsWithData: complete.count, fixedMonthly: fixed,
                              fixedToIncomeBasisPoints: ratio,
                              weakest: completeAfter.min { $0.income < $1.income },
                              strongest: completeAfter.max { $0.income < $1.income })
    }
}
