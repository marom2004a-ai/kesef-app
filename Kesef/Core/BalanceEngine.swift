import Foundation

public struct PeriodSummary: Hashable, Sendable {
    public var income: Money = .zero
    public var expenses: Money = .zero
    public var refunds: Money = .zero
    public var netExpenses: Money { expenses - refunds }
    public var net: Money { income - netExpenses }
    public init() {}
}

/// חישובי יתרות וסיכומים. רק תנועות בסטטוס confirmed משפיעות על יתרה.
public enum BalanceEngine {

    /// ההשפעה של תנועה מאושרת על חשבון מסוים
    public static func effect(of e: EntrySnapshot, on accountID: UUID) -> Money {
        guard e.status == .confirmed else { return .zero }
        var delta = Money.zero
        switch e.kind {
        case .income, .refund:
            if e.accountID == accountID { delta += e.amount }
        case .expense:
            if e.accountID == accountID { delta -= e.amount }
        case .transfer, .cardPayment, .ownerDraw, .partnerPayout, .taxPayment:
            if e.accountID == accountID { delta -= e.amount }
            if e.toAccountID == accountID { delta += e.amount }
        }
        return delta
    }

    /// האם התנועה כבר כלולה ביתרה הידועה (נרשמה לפני עדכון היתרה)
    static func isAfterBalanceDate(_ e: EntrySnapshot, _ a: AccountSnapshot) -> Bool {
        if e.date >= a.balanceDate { return true }
        // תנועה עם אותו יום שנוצרה אחרי עדכון היתרה — נספרת
        let cal = FinanceCalendar.israel
        return cal.isSameDay(e.date, a.balanceDate) && e.createdAt >= a.balanceDate
    }

    public static func balance(of a: AccountSnapshot, entries: [EntrySnapshot], asOf: Date? = nil) -> Money {
        var total = a.knownBalance
        for e in entries where isAfterBalanceDate(e, a) {
            if let asOf, e.date > asOf { continue }
            total += effect(of: e, on: a.id)
        }
        return total
    }

    public static func balances(accounts: [AccountSnapshot], entries: [EntrySnapshot]) -> [UUID: Money] {
        var result: [UUID: Money] = [:]
        for a in accounts { result[a.id] = balance(of: a, entries: entries) }
        return result
    }

    /// סך הכסף הזמין: חשבונות נזילים בלבד (בלי כרטיסי אשראי וחיסכון)
    public static func liquidTotal(accounts: [AccountSnapshot], entries: [EntrySnapshot]) -> Money {
        accounts.filter { $0.kind.isLiquid && $0.includeInTotals }
            .map { balance(of: $0, entries: entries) }.sum()
    }

    /// חוב בכרטיסי אשראי (מספר שלילי או אפס)
    public static func creditCardDebt(accounts: [AccountSnapshot], entries: [EntrySnapshot]) -> Money {
        accounts.filter { $0.kind == .creditCard && $0.includeInTotals }
            .map { balance(of: $0, entries: entries) }.sum()
    }

    public static func savingsTotal(accounts: [AccountSnapshot], entries: [EntrySnapshot]) -> Money {
        accounts.filter { $0.kind == .savings && $0.includeInTotals }
            .map { balance(of: $0, entries: entries) }.sum()
    }

    /// סיכום הכנסות/הוצאות מאושרות בתקופה (ללא העברות — מונע ספירה כפולה)
    public static func summary(entries: [EntrySnapshot], in period: Range<Date>, scope: Scope? = nil) -> PeriodSummary {
        var s = PeriodSummary()
        for e in entries where e.status == .confirmed && period.contains(e.date) {
            // משיכה מהעסק: בצד האישי זו הכנסה ("הכנסה מהעסק"); בעסק ובסה״כ — העברה פנימית, לא רווח ולא הוצאה
            if e.kind == .ownerDraw {
                if scope == .personal { s.income += e.amount }
                continue
            }
            if let scope, e.scope != scope { continue }
            switch e.kind {
            case .income: s.income += e.amount
            case .expense: s.expenses += e.amount
            case .refund: s.refunds += e.amount
            default: break
            }
        }
        return s
    }

    /// הוצאות נטו לפי קטגוריה (הוצאות פחות זיכויים)
    public static func expensesByCategory(entries: [EntrySnapshot], in period: Range<Date>, scope: Scope? = nil) -> [UUID?: Money] {
        var result: [UUID?: Money] = [:]
        for e in entries where e.status == .confirmed && period.contains(e.date) {
            if let scope, e.scope != scope { continue }
            if e.kind == .expense { result[e.categoryID, default: .zero] += e.amount }
            if e.kind == .refund { result[e.categoryID, default: .zero] -= e.amount }
        }
        return result
    }

    public static func lastBalanceUpdate(accounts: [AccountSnapshot]) -> Date? {
        accounts.filter { $0.kind.isLiquid && $0.includeInTotals }.map(\.balanceDate).max()
    }
}

// MARK: - שותף

public struct PartnerStatement: Hashable, Sendable {
    /// בסיס החישוב (רווח או הכנסות)
    public var base: Money
    public var share: Money
    public var paid: Money
    /// חיובי = עוד מגיע לשותף
    public var owed: Money { share - paid }
}

public enum PartnerEngine {
    public static func statement(entries: [EntrySnapshot], period: Range<Date>, settings: PartnerSettings) -> PartnerStatement {
        let business = BalanceEngine.summary(entries: entries, in: period, scope: .business)
        let base: Money = settings.basis == .profit ? business.net : business.income
        let share = base.isPositive ? base.multiplied(byBasisPoints: settings.shareBasisPoints) : .zero
        let paid = entries.filter { $0.status == .confirmed && $0.kind == .partnerPayout && period.contains($0.date) }
            .map(\.amount).sum()
        return PartnerStatement(base: base, share: share, paid: paid)
    }
}
