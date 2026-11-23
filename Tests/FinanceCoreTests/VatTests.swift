import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class VatTests: XCTestCase {
    let vat = VatSettings(isRegistered: true, rateBasisPoints: 1800, periodMonths: 2, dueDay: 15)

    func testVatIncludedInGross() {
        XCTAssertEqual(VatEngine.vatIncluded(in: ILS(118), rateBasisPoints: 1800), ILS(18))
        XCTAssertEqual(VatEngine.vatIncluded(in: ILS(1000), rateBasisPoints: 1800), Money(minorUnits: 15254)) // 152.54
        XCTAssertEqual(VatEngine.vatIncluded(in: ILS(100), rateBasisPoints: 0), .zero)
    }

    func testBimonthlyPeriodsAndDueDate() {
        let p = VatEngine.period(containing: D(2026, 11, 20), settings: vat, calendar: cal)
        XCTAssertEqual(cal.calendar.component(.month, from: p.lowerBound), 11)
        XCTAssertEqual(cal.calendar.component(.month, from: p.upperBound), 1) // ינואר 2027 (לא כולל)
        let due = VatEngine.dueDate(for: p, settings: vat, calendar: cal)
        XCTAssertEqual(cal.calendar.dateComponents([.year, .month, .day], from: due), DateComponents(year: 2027, month: 1, day: 15))
        let prev = VatEngine.previousPeriod(before: p, settings: vat, calendar: cal)
        XCTAssertEqual(cal.calendar.component(.month, from: prev.lowerBound), 9)
        let monthly = VatSettings(isRegistered: true, periodMonths: 1)
        XCTAssertEqual(cal.calendar.component(.month, from: VatEngine.period(containing: D(2026, 12, 3), settings: monthly, calendar: cal).lowerBound), 12)
    }

    func testStatementWithDeductibleCategories() {
        let car = UUID(), food = UUID()
        let entries = [
            income(ILS(11_800), D(2026, 11, 3)),                                  // מע״מ עסקאות 1,800
            expense(ILS(2_360), D(2026, 11, 5), category: food, scope: .business), // מע״מ תשומות 360 (100%)
            expense(ILS(1_180), D(2026, 12, 2), category: car, scope: .business),  // מע״מ 180 × 2/3
            expense(ILS(590), D(2026, 11, 7), scope: .personal),                   // אישי — לא נספר
            income(ILS(5_000), D(2027, 1, 2))                                      // תקופה אחרת
        ]
        let st = VatEngine.statement(entries: entries, period: VatEngine.period(containing: D(2026, 11, 1), settings: vat, calendar: cal),
                                     settings: vat, deductibleBP: [car: 6667, food: 10_000], calendar: cal)
        XCTAssertEqual(st.incomeGross, ILS(11_800))
        XCTAssertEqual(st.outputVAT, ILS(1_800))
        // רכב: 180 × 66.67% = 120.01 (2/3 מעוגל לנקודות בסיס)
        XCTAssertEqual(st.inputVAT, ILS(480, 1))      // 360 + 120.01
        XCTAssertEqual(st.vatPayable, ILS(1_319, 99))
        XCTAssertEqual(st.incomeNet, ILS(10_000))
        XCTAssertEqual(st.expensesNet, ILS(3_059, 99)) // 3,540 − 480.01
        XCTAssertEqual(st.profitBeforeTax, ILS(6_940, 1))
    }

    func testExplicitVatFromReportWins() {
        var e = expense(ILS(1_000), D(2026, 11, 5), scope: .business)
        e.vatOverride = ILS(100)
        let st = VatEngine.statement(entries: [e], period: VatEngine.period(containing: D(2026, 11, 5), settings: vat, calendar: cal), settings: vat, calendar: cal)
        XCTAssertEqual(st.inputVAT, ILS(100))
    }

    func testExemptDealerHasNoVat() {
        let exempt = VatSettings(isRegistered: false)
        let st = VatEngine.statement(entries: [income(ILS(11_800), D(2026, 11, 3))],
                                     period: VatEngine.period(containing: D(2026, 11, 3), settings: exempt, calendar: cal), settings: exempt, calendar: cal)
        XCTAssertEqual(st.vatPayable, .zero)
        XCTAssertEqual(st.profitBeforeTax, ILS(11_800))
    }

    func testHalfHalfSplitAfterVat() {
        let partner = PartnerSettings(name: "מרום", shareBasisPoints: 5000, basis: .profit)
        let entries = [
            income(ILS(11_800), D(2026, 11, 3)),
            expense(ILS(2_360), D(2026, 11, 5), scope: .business),
            EntrySnapshot(kind: .partnerPayout, amount: ILS(1_000), date: D(2026, 11, 20))
        ]
        let s = PartnerEngine.split(entries: entries, period: cal.monthRange(D(2026, 11, 1)), partner: partner, vat: vat, calendar: cal)
        // רווח: 10,000 − 2,000 = 8,000 → 4,000 לכל אחד
        XCTAssertEqual(s.base, ILS(8_000))
        XCTAssertEqual(s.partnerShare, ILS(4_000))
        XCTAssertEqual(s.myShare, ILS(4_000))
        XCTAssertEqual(s.stillOwedToPartner, ILS(3_000))
    }

    func testVatPaymentAppearsInForecastAndReducesSafeToSpend() {
        let bank = AccountSnapshot(name: "עסקי", kind: .businessBank, scope: .business, knownBalance: ILS(20_000), balanceDate: D(2026, 9, 1))
        let entries = [income(ILS(11_800), D(2026, 9, 10), account: bank.id)] // תקופה ספט׳–אוק׳ → משולם 15/11
        let input = ForecastInput(now: D(2026, 11, 1), horizonEnd: D(2026, 12, 1, 0), accounts: [bank], entries: entries, recurring: [],
                                  includeVariableSpending: false, vat: vat)
        let r = ForecastEngine.run(input, scenario: .base, calendar: cal)
        let ev = r.events.first { $0.kind == .vatPayment }
        XCTAssertEqual(ev?.amount, ILS(-1_800))
        XCTAssertEqual(ev.map { cal.day($0.date) }, 15)
        XCTAssertEqual(r.endBalance, ILS(31_800 - 1_800))

        // אחרי שנרשם תשלום מע״מ — לא נספר שוב
        let paid = entries + [EntrySnapshot(kind: .taxPayment, amount: ILS(1_800), date: D(2026, 11, 14), accountID: bank.id)]
        let r2 = ForecastEngine.run(ForecastInput(now: D(2026, 11, 1), horizonEnd: D(2026, 12, 1, 0), accounts: [bank], entries: paid,
                                                  recurring: [], includeVariableSpending: false, vat: vat), scenario: .base, calendar: cal)
        XCTAssertNil(r2.events.first { $0.kind == .vatPayment && $0.title.contains("2026-09") })
    }

    func testReportImportWithVatColumnAndExcelDates() {
        let table = CSVParser.parse("תאריך,ספק,סכום כולל מע\"מ,מע\"מ\n46331,חנות חיות,1180,180\n06/11/2026,דלק,236,36\n")
        let m = CSVImportEngine.guessMapping(table)
        XCTAssertEqual(m.amountColumn, 2)
        XCTAssertEqual(m.vatColumn, 3)
        let rows = CSVImportEngine.rows(from: table, mapping: m)
        XCTAssertEqual(rows[0].vat, ILS(180))
        XCTAssertEqual(rows[1].vat, ILS(36))
        // 46331 = 5 בנובמבר 2026 בתאריכי אקסל
        XCTAssertEqual(rows[0].date.map { cal.calendar.dateComponents([.year, .month, .day], from: $0) }, DateComponents(year: 2026, month: 11, day: 5))
    }
}
