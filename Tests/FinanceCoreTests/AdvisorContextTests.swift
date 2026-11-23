import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class AdvisorContextTests: XCTestCase {
    func testSummaryContainsKeyFiguresAndNoAccountNames() {
        let rest = CategorySnapshot(name: "מסעדות", scope: .personal, isEssential: false)
        let bank = AccountSnapshot(name: "חשבון-סודי-123", kind: .bank, knownBalance: ILS(5_000), balanceDate: D(2026, 9, 1))
        var entries: [EntrySnapshot] = []
        for i in 0..<4 { entries.append(expense(ILS(80), D(2026, 11, 2 + i), account: bank.id, category: rest.id)) }
        entries[0].title = "קפה ארומה"; entries[1].title = "קפה ארומה"; entries[2].title = "קפה ארומה"; entries[3].title = "פיצה"
        entries.append(income(ILS(11_800), D(2026, 11, 3), account: bank.id))
        let rule = RecurringSnapshot(title: "נטפליקס", amount: ILS(55), dayOfMonth: 5, startDate: D(2026, 1, 1), categoryID: rest.id)
        let text = AdvisorContext.build(AdvisorContextInput(
            now: D(2026, 11, 20), entries: entries, categories: [rest], recurring: [rule], budgets: [BudgetSnapshot(categoryID: rest.id, limit: ILS(200))],
            accounts: [bank], partner: PartnerSettings(name: "מרום", shareBasisPoints: 5000, basis: .profit),
            vat: VatSettings(isRegistered: true), reserve: ILS(1_000)), calendar: cal)

        XCTAssertTrue(text.contains("קפה ארומה [אישי]: 3 פעמים, 240 ₪"))
        XCTAssertTrue(text.contains("נטפליקס"))
        XCTAssertTrue(text.contains("מסעדות [א,לא חיוני] 320 ₪"))
        XCTAssertTrue(text.contains("מסעדות: נוצל 320 ₪ מתוך 200 ₪"))
        XCTAssertTrue(text.contains("שותף מרום 50%"))
        XCTAssertTrue(text.contains("מע״מ עסקאות 1800 ₪"))
        XCTAssertFalse(text.contains("חשבון-סודי-123"), "שמות חשבונות לא נשלחים")
    }

    func testEmptyDataStillBuilds() {
        let text = AdvisorContext.build(AdvisorContextInput(now: D(2026, 11, 20), entries: [], categories: [], recurring: [], budgets: [],
                                                            accounts: [], partner: nil, vat: nil), calendar: cal)
        XCTAssertTrue(text.contains("תאריך היום: 20/11/2026"))
        XCTAssertTrue(text.contains("צריך עוד נתונים"))
    }
}
