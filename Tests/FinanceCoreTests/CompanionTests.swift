import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class CompanionTests: XCTestCase {
    let vat = VatSettings(isRegistered: true, rateBasisPoints: 1800, periodMonths: 2, dueDay: 15)

    func testBusinessProfitSeriesPerMonth() {
        let entries = [
            income(ILS(1180), D(2026, 10, 5)),                     // אוקטובר: 1000 נטו
            income(ILS(2360), D(2026, 11, 5)),                     // נובמבר: 2000 נטו
            expense(ILS(118), D(2026, 11, 6), scope: .business),   // פחות 100 נטו
        ]
        let s = MonthlySeries.businessProfit(entries: entries, months: 3, now: D(2026, 11, 20), vat: vat, calendar: cal)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(cal.calendar.component(.month, from: s[0].monthStart), 9)
        XCTAssertEqual(s.map(\.value), [.zero, ILS(1000), ILS(1900)])
        XCTAssertTrue(MonthlySeries.isRecord(s))
        XCTAssertEqual(MonthlySeries.changeBP(current: ILS(1900), previous: ILS(1000)), 9000)
        XCTAssertNil(MonthlySeries.changeBP(current: ILS(10), previous: .zero))
    }

    func testPersonalNetSeries() {
        let entries = [income(ILS(5000), D(2026, 11, 1), scope: .personal), expense(ILS(1200), D(2026, 11, 2))]
        let s = MonthlySeries.personalNet(entries: entries, months: 2, now: D(2026, 11, 20), calendar: cal)
        XCTAssertEqual(s.last?.value, ILS(3800))
        XCTAssertFalse(MonthlySeries.isRecord([MonthPoint(monthStart: .now, value: .zero)]))
    }

    func testReceiptStreak() {
        XCTAssertEqual(Streaks.receipts(hasReceiptNewestFirst: [true, true, true, false, true]), 3)
        XCTAssertEqual(Streaks.receipts(hasReceiptNewestFirst: [false, true]), 0)
        XCTAssertEqual(Streaks.receipts(hasReceiptNewestFirst: []), 0)
    }

    func testCompanionPriorities() {
        XCTAssertEqual(CompanionAdvisor.message(.init(isBusiness: true, pendingCount: 2, missingReceipts: 3)).mood, .alert)
        XCTAssertTrue(CompanionAdvisor.message(.init(isBusiness: true, pendingCount: 2)).text.contains("2"))
        XCTAssertTrue(CompanionAdvisor.message(.init(isBusiness: true, missingReceipts: 3)).text.contains("3 קבלות"))
        // בצד האישי לא מדברים על קבלות עסקיות
        XCTAssertFalse(CompanionAdvisor.message(.init(isBusiness: false, missingReceipts: 3)).text.contains("קבל"))
        XCTAssertEqual(CompanionAdvisor.message(.init(isBusiness: true, isRecordMonth: true)).mood, .proud)
        XCTAssertTrue(CompanionAdvisor.message(.init(isBusiness: true, changeBP: 2500)).text.contains("25%"))
        XCTAssertEqual(CompanionAdvisor.message(.init(isBusiness: false, savedThisMonth: ILS(1000), savingsTarget: ILS(1000))).mood, .proud)
        XCTAssertTrue(CompanionAdvisor.message(.init(isBusiness: false, savedThisMonth: ILS(500), savingsTarget: ILS(1000))).text.contains("50%"))
        XCTAssertEqual(CompanionAdvisor.message(.init(isBusiness: true, changeBP: -3000, dayOfMonth: 25)).mood, .calm)
        XCTAssertTrue(CompanionAdvisor.message(.init(isBusiness: true, receiptStreak: 7)).text.contains("7"))
        XCTAssertEqual(CompanionAdvisor.message(.init(isBusiness: true)).mood, .calm)
    }
}
