import Foundation

public enum BudgetLevel: Int, Sendable, Comparable {
    case ok = 0, projectedOver = 1, warning = 2, over = 3
    public static func < (l: BudgetLevel, r: BudgetLevel) -> Bool { l.rawValue < r.rawValue }
    public var label: String {
        switch self {
        case .ok: return "בתקציב"
        case .projectedOver: return "צפויה חריגה"
        case .warning: return "מתקרב לתקרה"
        case .over: return "חריגה"
        }
    }
}

public struct BudgetStatus: Sendable, Identifiable {
    public var id: UUID { budgetID }
    public var budgetID: UUID
    public var categoryID: UUID
    public var limit: Money
    public var used: Money
    public var remaining: Money { limit - used }
    /// נקודות בסיס: 10000 = 100%
    public var usedBasisPoints: Int
    /// הערכה לסוף החודש לפי קצב ההוצאה עד היום (nil לחודש שאינו הנוכחי)
    public var projected: Money?
    public var level: BudgetLevel
}

public enum BudgetEngine {
    public static func status(budgets: [BudgetSnapshot], entries: [EntrySnapshot], month: Date, now: Date,
                              alertBasisPoints: Int = 8000, calendar cal: FinanceCalendar = .israel) -> [BudgetStatus] {
        let period = cal.monthRange(month)
        let byCat = BalanceEngine.expensesByCategory(entries: entries, in: period)
        let isCurrent = period.contains(now)
        let elapsed = Swift.max(1, cal.daysBetween(period.lowerBound, now) + 1)
        let totalDays = cal.daysInMonth(month)

        return budgets.map { b in
            let used = byCat[b.categoryID] ?? .zero
            let bp = Money.ratioBasisPoints(used, of: b.limit) ?? 0
            var projected: Money? = nil
            if isCurrent && elapsed < totalDays {
                projected = Money(minorUnits: Money.roundedDivide(used.minorUnits * Int64(totalDays), by: Int64(elapsed)))
            }
            var level: BudgetLevel = .ok
            if used > b.limit { level = .over }
            else if bp >= alertBasisPoints { level = .warning }
            else if let p = projected, p > b.limit, elapsed >= 7 { level = .projectedOver }
            return BudgetStatus(budgetID: b.id, categoryID: b.categoryID, limit: b.limit, used: used,
                                usedBasisPoints: bp, projected: projected, level: level)
        }
    }
}
