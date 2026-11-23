import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class ForecastTests: XCTestCase {
    let now = D(2026, 11, 10, 10)
    lazy var bank = AccountSnapshot(name: "בנק", kind: .bank, knownBalance: ILS(3000), balanceDate: D(2026, 11, 10, 8))
    lazy var card = AccountSnapshot(name: "אשראי", kind: .creditCard, balanceDate: D(2026, 11, 1, 8), billingDay: 15)

    func input(_ entries: [EntrySnapshot], recurring: [RecurringSnapshot] = [], days: Int = 30,
               partner: PartnerSettings? = nil, savings: Money = .zero) -> ForecastInput {
        ForecastInput(now: now, horizonEnd: cal.addDays(days, to: cal.startOfDay(now)), accounts: [bank, card],
                      entries: entries, recurring: recurring, partner: partner, monthlySavingsTarget: savings,
                      includeVariableSpending: false)
    }

    func testExpectedIncomeByScenario() {
        let entries = [
            income(ILS(1000), D(2026, 11, 12), account: bank.id, status: .planned, certainty: .high),
            income(ILS(500), D(2026, 11, 13), account: bank.id, status: .planned, certainty: .medium),
            income(ILS(200), D(2026, 11, 14), account: bank.id, status: .planned, certainty: .low)
        ]
        XCTAssertEqual(ForecastEngine.run(input(entries), scenario: .conservative, calendar: cal).endBalance, ILS(4000))
        XCTAssertEqual(ForecastEngine.run(input(entries), scenario: .base, calendar: cal).endBalance, ILS(4500))
        XCTAssertEqual(ForecastEngine.run(input(entries), scenario: .optimistic, calendar: cal).endBalance, ILS(4700))
    }

    func testExpectedIncomeDoesNotChangeCurrentBalance() {
        let entries = [income(ILS(9999), D(2026, 11, 12), account: bank.id, status: .planned)]
        XCTAssertEqual(ForecastEngine.run(input(entries), scenario: .optimistic, calendar: cal).startBalance, ILS(3000))
    }

    func testRecurringChargeAndNegativeWarning() {
        let rent = RecurringSnapshot(title: "שכירות", amount: ILS(3500), dayOfMonth: 20, startDate: D(2026, 1, 1), accountID: bank.id)
        let r = ForecastEngine.run(input([], recurring: [rent], days: 20), scenario: .base, calendar: cal)
        XCTAssertEqual(r.endBalance, ILS(-500))
        XCTAssertEqual(r.firstNegativeDate.map { cal.day($0) }, 20)
        XCTAssertEqual(r.minBalance, ILS(-500))
    }

    func testRecordedOccurrenceIsNotCountedTwice() {
        let ruleID = UUID()
        let rent = RecurringSnapshot(id: ruleID, title: "שכירות", amount: ILS(1000), dayOfMonth: 20, startDate: D(2026, 1, 1), accountID: bank.id)
        let recorded = expense(ILS(1000), D(2026, 11, 20), account: bank.id, status: .planned, rule: ruleID, occurrence: D(2026, 11, 20, 0))
        let r = ForecastEngine.run(input([recorded], recurring: [rent], days: 20), scenario: .base, calendar: cal)
        XCTAssertEqual(r.endBalance, ILS(2000))
    }

    func testCardPurchasesHitBankOnBillingDay() {
        let purchase = expense(ILS(400), D(2026, 11, 5), account: card.id)       // מאושרת → חוב בכרטיס
        let pending = expense(ILS(100), D(2026, 11, 10), account: card.id, status: .pendingReview)
        let r = ForecastEngine.run(input([purchase, pending], days: 10), scenario: .base, calendar: cal)
        // ההתחלה לא מושפעת מהכרטיס
        XCTAssertEqual(r.startBalance, ILS(3000))
        let day14 = r.points.first { cal.day($0.date) == 14 }!
        XCTAssertEqual(day14.balance, ILS(3000))
        let day15 = r.points.first { cal.day($0.date) == 15 }!
        XCTAssertEqual(day15.balance, ILS(2500))
    }

    func testPartnerAndSavingsAtMonthEnd() {
        let p = PartnerSettings(name: "שותף", shareBasisPoints: 5000, basis: .revenue)
        let entries = [income(ILS(2000), D(2026, 11, 3), account: bank.id)] // לפני עדכון היתרה — כבר כלול ביתרה
        let r = ForecastEngine.run(input(entries, partner: p, savings: ILS(300)), scenario: .base, calendar: cal)
        XCTAssertEqual(r.events.first { $0.kind == .partnerShare }?.amount, ILS(-1000))
        XCTAssertEqual(r.events.first { $0.kind == .savingsTarget }?.amount, ILS(-300))
        XCTAssertEqual(cal.day(r.events.first { $0.kind == .partnerShare }!.date), 30)
        XCTAssertEqual(r.endBalance, ILS(1700))
    }

    func testVariableSpendingNeedsHistory() {
        let e = [expense(ILS(100), D(2026, 11, 1), account: bank.id)]
        XCTAssertNil(ForecastEngine.averageDailyVariableSpend(entries: e, now: now, calendar: cal))
        var long: [EntrySnapshot] = []
        for i in 0..<60 { long.append(expense(ILS(30), cal.addDays(-60 + i, to: cal.startOfDay(now)), account: bank.id)) }
        long.append(expense(ILS(5000), D(2026, 11, 1), account: bank.id, fixed: true)) // קבועה — לא נספרת
        XCTAssertEqual(ForecastEngine.averageDailyVariableSpend(entries: long, now: now, calendar: cal), ILS(30))
    }

    func testDashboardSafeToSpendUsesConservativeMinimumMinusReserve() {
        let rent = RecurringSnapshot(title: "שכירות", amount: ILS(2000), dayOfMonth: 20, startDate: D(2026, 1, 1), accountID: bank.id)
        let entries = [income(ILS(5000), D(2026, 11, 25), account: bank.id, status: .planned, certainty: .medium)]
        let d = DashboardEngine.build(now: now, accounts: [bank, card], entries: entries, recurring: [rent], partner: nil,
                                      monthlySavingsTarget: .zero, reserve: ILS(500), calendar: cal)
        XCTAssertEqual(d.currentBalance, ILS(3000))
        XCTAssertEqual(d.forecastEndOfMonth, ILS(6000))
        XCTAssertEqual(d.forecastEndOfMonthConservative, ILS(1000))
        XCTAssertEqual(d.safeToSpend, ILS(500))
        XCTAssertEqual(d.expectedIncome, ILS(5000))
        XCTAssertEqual(d.upcomingExpenses, ILS(2000))
    }
}

final class BudgetTests: XCTestCase {
    func testBudgetLevels() {
        let food = UUID(), fun = UUID(), car = UUID()
        let budgets = [BudgetSnapshot(categoryID: food, limit: ILS(1000)),
                       BudgetSnapshot(categoryID: fun, limit: ILS(500)),
                       BudgetSnapshot(categoryID: car, limit: ILS(1000))]
        let entries = [
            expense(ILS(850), D(2026, 11, 5), category: food),
            expense(ILS(600), D(2026, 11, 5), category: fun),
            expense(ILS(450), D(2026, 11, 7), category: car)
        ]
        let st = BudgetEngine.status(budgets: budgets, entries: entries, month: D(2026, 11, 1), now: D(2026, 11, 10), calendar: cal)
        XCTAssertEqual(st[0].level, .warning)
        XCTAssertEqual(st[0].usedBasisPoints, 8500)
        XCTAssertEqual(st[0].remaining, ILS(150))
        XCTAssertEqual(st[1].level, .over)
        XCTAssertEqual(st[1].remaining, ILS(-100))
        // 450 ב-10 ימים → 1350 צפוי בחודש של 30 יום
        XCTAssertEqual(st[2].projected, ILS(1350))
        XCTAssertEqual(st[2].level, .projectedOver)
    }
}

final class IncomeAnalyzerTests: XCTestCase {
    func testAveragesAndStrength() {
        var entries: [EntrySnapshot] = []
        let incomes: [Int64] = [10000, 12000, 8000, 14000, 6000, 10000] // מאי–אוקטובר
        for (i, v) in incomes.enumerated() { entries.append(income(ILS(v), D(2026, 5 + i, 10))) }
        entries.append(income(ILS(3000), D(2026, 11, 2)))
        let a = IncomeAnalyzer.analyze(entries: entries, recurring: [], now: D(2026, 11, 15), calendar: cal)
        XCTAssertEqual(a.completeMonthsWithData, 5) // מאי לא שלם — הנתונים מתחילים ב-10 בחודש
        XCTAssertEqual(a.average3, ILS(10000))     // אוג׳–אוק׳: 14000, 6000, 10000
        XCTAssertNil(a.average6)
        XCTAssertEqual(a.weakest?.income, ILS(6000))
        let sep = a.months.first { cal.calendar.component(.month, from: $0.monthStart) == 9 }!
        XCTAssertEqual(sep.strength, .weak)
        let aug = a.months.first { cal.calendar.component(.month, from: $0.monthStart) == 8 }!
        XCTAssertEqual(aug.strength, .strong)
    }
}

final class AdvisorTests: XCTestCase {
    func testRecommendationsAreBasedOnDataOnly() {
        let rest = CategorySnapshot(name: "מסעדות", scope: .personal, isEssential: false)
        var entries: [EntrySnapshot] = []
        for m in 6...9 { entries.append(income(ILS(10000), D(2026, m, 1, 9))) }
        for m in 7...9 { entries.append(expense(ILS(500), D(2026, m, 5), category: rest.id)) }
        entries.append(expense(ILS(1200), D(2026, 10, 5), category: rest.id))
        entries.append(income(ILS(10000), D(2026, 10, 1, 9)))
        let recs = SavingsAdvisor.recommendations(AdvisorInput(now: D(2026, 11, 15), entries: entries, recurring: [],
                                                               categories: [rest], accounts: []), calendar: cal)
        let growth = recs.first { $0.id.hasPrefix("growth-") }
        XCTAssertNotNil(growth)
        XCTAssertEqual(growth?.monthlyPotential, ILS(700))
        XCTAssertFalse(growth!.basis.isEmpty)
        XCTAssertNotNil(recs.first { $0.id == "non-essential" })
        XCTAssertNotNil(recs.first { $0.id == "savings-goal" })
        XCTAssertNil(recs.first { $0.id == "need-data" })
    }

    func testNoDataGivesOnlyNeedDataMessage() {
        let recs = SavingsAdvisor.recommendations(AdvisorInput(now: D(2026, 11, 15), entries: [], recurring: [], categories: [], accounts: []), calendar: cal)
        XCTAssertEqual(recs.map(\.id), ["need-data"])
    }
}
