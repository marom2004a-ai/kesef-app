import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class PeriodReportTests: XCTestCase {
    let vat = VatSettings(isRegistered: true, rateBasisPoints: 1800, periodMonths: 2, dueDay: 15)

    private func sample(car: UUID) -> [EntrySnapshot] {
        var refund = expense(ILS(59), D(2026, 11, 22), scope: .business)
        refund.kind = .refund
        return [
            income(ILS(1180), D(2026, 11, 3)),
            income(ILS(590), D(2026, 12, 10)),
            income(ILS(500), D(2026, 12, 11), scope: .personal),                 // אישי — לא בדוח
            income(ILS(999), D(2026, 12, 12), status: .planned),                // צפוי — לא בדוח
            income(ILS(236), D(2027, 1, 2)),                                     // תקופה הבאה
            expense(ILS(236), D(2026, 11, 5), scope: .business),
            expense(ILS(1180), D(2026, 12, 1), category: car, scope: .business), // רכב — 2/3 מהמע״מ
            expense(ILS(100), D(2026, 12, 2), scope: .personal),
            refund,
        ]
    }

    func testReportMatchesVatStatement() {
        let car = UUID()
        let entries = sample(car: car)
        let p = VatEngine.period(containing: D(2026, 11, 15), settings: vat, calendar: cal)
        let ded = [car: 6667]
        let r = PeriodReportEngine.build(entries: entries, period: p, settings: vat, deductibleBP: ded)
        let st = VatEngine.statement(entries: entries, period: p, settings: vat, deductibleBP: ded, calendar: cal)

        XCTAssertEqual(r.income.count, 2)
        XCTAssertEqual(r.expenses.count, 3)
        XCTAssertEqual(r.incomeGross, ILS(1770))
        XCTAssertEqual(r.incomeVAT, ILS(270))
        XCTAssertEqual(r.incomeNet, ILS(1500))
        XCTAssertEqual(r.incomeGross, st.incomeGross)
        XCTAssertEqual(r.incomeVAT, st.outputVAT)
        XCTAssertEqual(r.expensesGross, st.expensesGross)
        XCTAssertEqual(r.expensesVAT, st.inputVAT)
        XCTAssertEqual(r.incomeNet - r.expensesNet, st.profitBeforeTax)
        // זיכוי נרשם בשלילה
        XCTAssertEqual(r.expenses.first { $0.kind == .refund }?.gross, -ILS(59))
        // ממוין לפי תאריך
        XCTAssertEqual(r.income.map(\.date), r.income.map(\.date).sorted())
    }

    func testMissingReceiptsCountsOnlyExpenses() {
        let car = UUID()
        let entries = sample(car: car)
        let p = VatEngine.period(containing: D(2026, 11, 15), settings: vat, calendar: cal)
        let withPhoto = Set(entries.filter { $0.kind == .expense && $0.amount == ILS(236) }.map(\.id))
        let r = PeriodReportEngine.build(entries: entries, withReceipt: withPhoto, period: p, settings: vat)
        XCTAssertEqual(r.expensesMissingReceipt, 1) // רק הוצאת הרכב; הזיכוי לא נספר
    }

    func testUnregisteredHasNoVAT() {
        let p = VatEngine.period(containing: D(2026, 11, 15), settings: vat, calendar: cal)
        let r = PeriodReportEngine.build(entries: sample(car: UUID()), period: p,
                                         settings: VatSettings(isRegistered: false))
        XCTAssertEqual(r.incomeVAT, .zero)
        XCTAssertEqual(r.incomeNet, r.incomeGross)
    }

    func testCSVHasRowsAndTotals() {
        let car = UUID()
        let p = VatEngine.period(containing: D(2026, 11, 15), settings: vat, calendar: cal)
        let r = PeriodReportEngine.build(entries: sample(car: car), period: p, settings: vat, deductibleBP: [car: 6667])
        let csv = PeriodReportEngine.csv(r, categoryNames: [car: "רכב"], calendar: cal)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}סוג,תאריך"))
        XCTAssertTrue(csv.contains("הכנסה,03/11/2026,לקוח בדיקה,,1180,180,1000,אין"))
        XCTAssertTrue(csv.contains("זיכוי על הוצאה,22/11/2026"))
        XCTAssertTrue(csv.contains(",רכב,1180,"))
        XCTAssertTrue(csv.contains("סיכום,,סה״כ הכנסות,,1770,270,1500,"))
    }
}
