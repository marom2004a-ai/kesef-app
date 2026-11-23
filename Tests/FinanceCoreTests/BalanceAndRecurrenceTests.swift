import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class BalanceTests: XCTestCase {
    let bank = AccountSnapshot(name: "בנק", kind: .bank, knownBalance: ILS(5000), balanceDate: D(2026, 11, 1, 9))
    let card = AccountSnapshot(name: "אשראי", kind: .creditCard, knownBalance: .zero, balanceDate: D(2026, 11, 1, 9), billingDay: 10)
    let savings = AccountSnapshot(name: "חיסכון", kind: .savings, knownBalance: ILS(10000), balanceDate: D(2026, 11, 1, 9))

    func testOnlyConfirmedAffectsBalance() {
        let entries = [
            expense(ILS(100), D(2026, 11, 2), account: bank.id),
            expense(ILS(50), D(2026, 11, 3), account: bank.id, status: .pendingReview),
            expense(ILS(70), D(2026, 11, 4), account: bank.id, status: .planned),
            expense(ILS(30), D(2026, 11, 4), account: bank.id, status: .cancelled),
            income(ILS(1000), D(2026, 11, 5), account: bank.id, status: .planned),
            income(ILS(400), D(2026, 11, 6), account: bank.id)
        ]
        XCTAssertEqual(BalanceEngine.balance(of: bank, entries: entries), ILS(5300))
    }

    func testEntriesBeforeKnownBalanceAreAlreadyIncluded() {
        let entries = [expense(ILS(100), D(2026, 10, 30), account: bank.id)]
        XCTAssertEqual(BalanceEngine.balance(of: bank, entries: entries), ILS(5000))
    }

    func testSameDayEntryCreatedAfterBalanceUpdateCounts() {
        var e = expense(ILS(20), D(2026, 11, 1, 0, 0), account: bank.id)
        e.createdAt = D(2026, 11, 1, 15)
        XCTAssertEqual(BalanceEngine.balance(of: bank, entries: [e]), ILS(4980))
    }

    func testCardPurchaseThenCardPaymentIsNotDoubleCounted() {
        let purchase = expense(ILS(300), D(2026, 11, 2), account: card.id)
        let payment = EntrySnapshot(kind: .cardPayment, amount: ILS(300), date: D(2026, 11, 10), accountID: bank.id, toAccountID: card.id)
        let entries = [purchase, payment]
        // הוצאות החודש = 300 בלבד (הסילוק אינו הוצאה)
        let s = BalanceEngine.summary(entries: entries, in: cal.monthRange(D(2026, 11, 15)))
        XCTAssertEqual(s.expenses, ILS(300))
        XCTAssertEqual(BalanceEngine.balance(of: card, entries: entries), .zero)
        XCTAssertEqual(BalanceEngine.balance(of: bank, entries: entries), ILS(4700))
        // יתרה נזילה לא כוללת חיסכון וכרטיס
        XCTAssertEqual(BalanceEngine.liquidTotal(accounts: [bank, card, savings], entries: entries), ILS(4700))
    }

    func testTransfersAreNotIncomeOrExpense() {
        let t = EntrySnapshot(kind: .transfer, amount: ILS(1000), date: D(2026, 11, 3), accountID: bank.id, toAccountID: savings.id)
        let s = BalanceEngine.summary(entries: [t], in: cal.monthRange(D(2026, 11, 3)))
        XCTAssertEqual(s.income, .zero)
        XCTAssertEqual(s.expenses, .zero)
        XCTAssertEqual(BalanceEngine.balance(of: savings, entries: [t]), ILS(11000))
    }

    func testRefundsReduceCategoryExpenses() {
        let cat = UUID()
        let entries = [
            expense(ILS(500), D(2026, 11, 2), account: bank.id, category: cat),
            EntrySnapshot(kind: .refund, amount: ILS(120), date: D(2026, 11, 8), categoryID: cat, accountID: bank.id)
        ]
        let byCat = BalanceEngine.expensesByCategory(entries: entries, in: cal.monthRange(D(2026, 11, 1)))
        XCTAssertEqual(byCat[cat], ILS(380))
        XCTAssertEqual(BalanceEngine.summary(entries: entries, in: cal.monthRange(D(2026, 11, 1))).netExpenses, ILS(380))
    }

    func testMonthBoundaryAndYearBoundary() {
        let entries = [
            expense(ILS(10), D(2026, 12, 31, 23, 59)),
            expense(ILS(20), D(2027, 1, 1, 0, 0))
        ]
        XCTAssertEqual(BalanceEngine.summary(entries: entries, in: cal.monthRange(D(2026, 12, 15))).expenses, ILS(10))
        XCTAssertEqual(BalanceEngine.summary(entries: entries, in: cal.monthRange(D(2027, 1, 15))).expenses, ILS(20))
    }

    func testPartnerShareOnProfit() {
        let p = PartnerSettings(name: "שותף", shareBasisPoints: 5000, basis: .profit)
        let entries = [
            income(ILS(10000), D(2026, 11, 3)),
            expense(ILS(2000), D(2026, 11, 4), scope: .business),
            expense(ILS(999), D(2026, 11, 4), scope: .personal), // אישי — לא משפיע על השותף
            EntrySnapshot(kind: .partnerPayout, amount: ILS(1000), date: D(2026, 11, 20), accountID: bank.id)
        ]
        let st = PartnerEngine.statement(entries: entries, period: cal.monthRange(D(2026, 11, 1)), settings: p)
        XCTAssertEqual(st.base, ILS(8000))
        XCTAssertEqual(st.share, ILS(4000))
        XCTAssertEqual(st.owed, ILS(3000))
    }

    func testPartnerShareOnLossIsZero() {
        let p = PartnerSettings(name: "שותף", shareBasisPoints: 4000, basis: .profit)
        let entries = [income(ILS(1000), D(2026, 11, 3)), expense(ILS(3000), D(2026, 11, 4), scope: .business)]
        XCTAssertEqual(PartnerEngine.statement(entries: entries, period: cal.monthRange(D(2026, 11, 1)), settings: p).share, .zero)
    }
}

final class RecurrenceTests: XCTestCase {
    func testMonthlyClampsTo28or29() {
        let r = RecurringSnapshot(title: "שכירות", amount: ILS(4000), dayOfMonth: 31, startDate: D(2026, 1, 1))
        let occ = RecurrenceEngine.occurrences(of: r, from: D(2027, 1, 1, 0), to: D(2027, 4, 1, 0), calendar: cal)
        XCTAssertEqual(occ.map { cal.day($0) }, [31, 28, 31])
        let leap = RecurrenceEngine.occurrences(of: r, from: D(2028, 2, 1, 0), to: D(2028, 3, 1, 0), calendar: cal)
        XCTAssertEqual(leap.map { cal.day($0) }, [29])
    }

    func testStartAndEndDatesRespected() {
        let r = RecurringSnapshot(title: "הלוואה", amount: ILS(800), dayOfMonth: 10, startDate: D(2026, 11, 15), endDate: D(2027, 2, 10))
        let occ = RecurrenceEngine.occurrences(of: r, from: D(2026, 11, 1, 0), to: D(2027, 6, 1, 0), calendar: cal)
        // נובמבר 10 לפני ההתחלה; דצמבר, ינואר, פברואר
        XCTAssertEqual(occ.count, 3)
        XCTAssertEqual(cal.day(occ[0]), 10)
    }

    func testPausedProducesNothing() {
        let r = RecurringSnapshot(title: "מנוי", amount: ILS(50), dayOfMonth: 5, startDate: D(2026, 1, 1), isPaused: true)
        XCTAssertTrue(RecurrenceEngine.occurrences(of: r, from: D(2026, 11, 1), to: D(2027, 1, 1), calendar: cal).isEmpty)
    }

    func testQuarterlyAndYearlyAndWeekly() {
        let q = RecurringSnapshot(title: "ביטוח", amount: ILS(600), frequency: .quarterly, dayOfMonth: 1, startDate: D(2025, 2, 1))
        let occ = RecurrenceEngine.occurrences(of: q, from: D(2026, 11, 1, 0), to: D(2027, 11, 1, 0), calendar: cal)
        XCTAssertEqual(occ.map { cal.calendar.component(.month, from: $0) }, [11, 2, 5, 8])

        let y = RecurringSnapshot(title: "רישיון", amount: ILS(1200), frequency: .yearly, dayOfMonth: 20, startDate: D(2024, 3, 20))
        XCTAssertEqual(RecurrenceEngine.occurrences(of: y, from: D(2026, 1, 1, 0), to: D(2027, 1, 1, 0), calendar: cal).count, 1)

        let w = RecurringSnapshot(title: "שבועי", amount: ILS(100), frequency: .weekly, dayOfMonth: 1, startDate: D(2026, 11, 2, 0))
        XCTAssertEqual(RecurrenceEngine.occurrences(of: w, from: D(2026, 11, 1, 0), to: D(2026, 12, 1, 0), calendar: cal).count, 5)
    }

    func testMonthlyEquivalent() {
        XCTAssertEqual(RecurringSnapshot(title: "", amount: ILS(1200), frequency: .yearly, dayOfMonth: 1, startDate: D(2026, 1, 1)).monthlyEquivalent, ILS(100))
        XCTAssertEqual(RecurringSnapshot(title: "", amount: ILS(120), frequency: .weekly, dayOfMonth: 1, startDate: D(2026, 1, 1)).monthlyEquivalent, ILS(520))
    }
}
