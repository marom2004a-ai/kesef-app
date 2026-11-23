import XCTest
import SwiftData
@testable import Kesef

/// בדיקות אינטגרציה מול SwiftData אמיתי בזיכרון: קליטת Apple Pay, כפילויות, אישור, פיצול, דחייה, גיבוי ושחזור.
/// נתונים מומצאים בלבד.
@MainActor
final class PendingFlowIntegrationTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext { container.mainContext }
    var clock = Date(timeIntervalSinceReferenceDate: 815_000_000)

    override func setUp() async throws {
        container = Persistence.makeContainer(inMemory: true)
        UserDefaults.standard.removeObject(forKey: AppSettings.Key.defaultApplePayScope)
        UserDefaults.standard.removeObject(forKey: AppSettings.Key.defaultApplePayAccount)
    }

    func service() -> PendingTransactionService {
        var s = PendingTransactionService(context: context)
        let t = clock
        s.now = { t }
        return s
    }

    func testIngestCreatesPendingPersonalNotConfirmed() throws {
        let r = try service().ingestApplePay(amountText: "₪42.90", merchant: "סופר בדיקה", cardLabel: "Visa 0000")
        guard case let .created(id, needs, dup) = r else { return XCTFail("expected created") }
        XCTAssertFalse(needs); XCTAssertFalse(dup)
        let e = try XCTUnwrap(Ledger(context: context).entry(id: id))
        XCTAssertEqual(e.status, .pendingReview)
        XCTAssertEqual(e.scope, .personal, "ברירת המחדל חייבת להיות אישית")
        XCTAssertEqual(e.amount, Money(minorUnits: 4290))
        XCTAssertEqual(e.source, .applePayShortcut)
        // לא נכנס לסיכום ההוצאות המאושרות
        let s = BalanceEngine.summary(entries: Ledger(context: context).entries().map(\.snapshot), in: FinanceCalendar.israel.monthRange(clock))
        XCTAssertEqual(s.expenses, .zero)
    }

    func testRerunDoesNotDuplicate() throws {
        _ = try service().ingestApplePay(amountText: "10", merchant: "קפה", cardLabel: "Visa")
        clock = clock.addingTimeInterval(30)
        let r = try service().ingestApplePay(amountText: "10.00", merchant: "קפה", cardLabel: "Visa")
        if case .duplicateIgnored = r {} else { XCTFail("rerun should be ignored") }
        XCTAssertEqual(Ledger(context: context).pendingCount(), 1)
    }

    func testRejectedPurchaseIsNotRecreatedByRerun() throws {
        guard case let .created(id, _, _) = try service().ingestApplePay(amountText: "10", merchant: "קפה", cardLabel: "Visa") else { return XCTFail() }
        try service().reject(Ledger(context: context).entry(id: id)!)
        clock = clock.addingTimeInterval(20)
        if case .duplicateIgnored = try service().ingestApplePay(amountText: "10", merchant: "קפה", cardLabel: "Visa") {} else { XCTFail() }
    }

    func testSimilarLaterPurchaseIsFlagged() throws {
        _ = try service().ingestApplePay(amountText: "14", merchant: "קפה", cardLabel: "Visa")
        clock = clock.addingTimeInterval(3600)
        guard case let .created(_, _, dup) = try service().ingestApplePay(amountText: "14", merchant: "קפה", cardLabel: "Visa") else { return XCTFail() }
        XCTAssertTrue(dup)
        XCTAssertEqual(Ledger(context: context).pendingCount(), 2)
    }

    func testMissingDetailsOpensForCompletion() throws {
        guard case let .created(id, needs, _) = try service().ingestApplePay(amountText: "", merchant: " ", cardLabel: nil) else { return XCTFail() }
        XCTAssertTrue(needs)
        let e = Ledger(context: context).entry(id: id)!
        XCTAssertEqual(e.status, .pendingReview)
        XCTAssertFalse(try service().quickConfirm(e), "אישור מהיר אסור כשחסרים פרטים")
    }

    func testConfirmAsBusiness() throws {
        guard case let .created(id, _, _) = try service().ingestApplePay(amountText: "300", merchant: "חנות חיות", cardLabel: "Visa") else { return XCTFail() }
        let e = Ledger(context: context).entry(id: id)!
        let food = Ledger(context: context).categories().first { $0.name == "מזון לכלבים" }!
        try service().confirm(e, with: .init(amount: Money(shekels: 300), title: "חנות חיות", scope: .business, categoryID: food.id,
                                              accountID: nil, note: "", businessSplitAmount: nil, businessCategoryID: nil, personalCategoryID: nil))
        XCTAssertEqual(e.status, .confirmed)
        XCTAssertEqual(e.scope, .business)
        XCTAssertEqual(e.categoryID, food.id)
        XCTAssertEqual(Ledger(context: context).pendingCount(), 0)
    }

    func testSplitSumsToOriginal() throws {
        guard case let .created(id, _, _) = try service().ingestApplePay(amountText: "250.50", merchant: "סופר", cardLabel: "Visa") else { return XCTFail() }
        let e = Ledger(context: context).entry(id: id)!
        let parts = try service().confirm(e, with: .init(amount: Money(minorUnits: 25050), title: "סופר", scope: .personal, categoryID: nil,
                                                         accountID: nil, note: "", businessSplitAmount: Money(minorUnits: 10025),
                                                         businessCategoryID: nil, personalCategoryID: nil))
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.map(\.amount).sum(), Money(minorUnits: 25050))
        XCTAssertEqual(Set(parts.map(\.scope)), [.personal, .business])
        XCTAssertTrue(parts.allSatisfy { $0.status == .confirmed })
        XCTAssertEqual(parts[0].splitGroupID, parts[1].splitGroupID)
    }

    func testInvalidSplitIsRejected() throws {
        guard case let .created(id, _, _) = try service().ingestApplePay(amountText: "100", merchant: "סופר", cardLabel: "Visa") else { return XCTFail() }
        let e = Ledger(context: context).entry(id: id)!
        XCTAssertThrowsError(try service().confirm(e, with: .init(amount: Money(shekels: 100), title: "סופר", scope: .personal, categoryID: nil,
                                                                  accountID: nil, note: "", businessSplitAmount: Money(shekels: 150),
                                                                  businessCategoryID: nil, personalCategoryID: nil)))
        XCTAssertEqual(e.status, .pendingReview)
    }

    func testCardAliasRemembered() throws {
        let card = Account(name: "אשראי בדיקה", kind: .creditCard, scope: .personal, billingDay: 10)
        context.insert(card); try context.save()
        guard case let .created(id, _, _) = try service().ingestApplePay(amountText: "20", merchant: "א", cardLabel: "Visa 1111") else { return XCTFail() }
        try service().confirm(Ledger(context: context).entry(id: id)!, with: .init(amount: Money(shekels: 20), title: "א", scope: .personal,
            categoryID: nil, accountID: card.id, note: "", businessSplitAmount: nil, businessCategoryID: nil, personalCategoryID: nil,
            rememberCardForAccount: true))
        clock = clock.addingTimeInterval(4000)
        guard case let .created(id2, _, _) = try service().ingestApplePay(amountText: "30", merchant: "ב", cardLabel: "visa 1111") else { return XCTFail() }
        XCTAssertEqual(Ledger(context: context).entry(id: id2)?.accountID, card.id)
    }

    func testDefaultScopeSettingIsRespected() throws {
        AppSettings.defaultApplePayScope = .business
        defer { AppSettings.defaultApplePayScope = .personal }
        guard case let .created(id, _, _) = try service().ingestApplePay(amountText: "5", merchant: "x", cardLabel: nil) else { return XCTFail() }
        XCTAssertEqual(Ledger(context: context).entry(id: id)?.scope, .business)
    }

    func testRecurringPostingIsIdempotent() throws {
        let cal = FinanceCalendar.israel
        let rule = RecurringRule(title: "שכירות בדיקה", amount: Money(shekels: 1000), dayOfMonth: cal.day(.now), startDate: cal.addMonths(-3, to: .now))
        rule.createdAt = cal.addDays(-1, to: .now)
        context.insert(rule); try context.save()
        let first = try LedgerService(context: context).postDueRecurring()
        let second = try LedgerService(context: context).postDueRecurring()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
    }

    func testPartialPaymentKeepsTotal() throws {
        let e = Entry(kind: .income, status: .planned, amount: Money(shekels: 1000), date: .now, title: "לקוח", scope: .business)
        context.insert(e); try context.save()
        try LedgerService(context: context).receivePartial(e, received: Money(shekels: 600), on: .now)
        let all = Ledger(context: context).entries().filter { $0.kind == .income }
        XCTAssertEqual(all.map(\.amount).sum(), Money(shekels: 1000))
        XCTAssertEqual(all.first { $0.status == .confirmed }?.amount, Money(shekels: 600))
        XCTAssertEqual(all.first { $0.status == .planned }?.amount, Money(shekels: 400))
    }

    func testInstallmentsSumToTotal() throws {
        let parts = try LedgerService(context: context).createInstallments(total: Money(shekels: 1000), count: 3, firstDate: .now,
            title: "קורס", scope: .business, categoryID: nil, accountID: nil, certainty: .medium, note: "")
        XCTAssertEqual(parts.map(\.amount).sum(), Money(shekels: 1000))
        XCTAssertTrue(parts.allSatisfy { $0.status == .planned })
    }

    func testEditAndDeletePersist() throws {
        let e = Entry(kind: .expense, status: .confirmed, amount: Money(shekels: 50), date: .now, title: "לפני", scope: .personal)
        context.insert(e); try context.save()
        e.title = "אחרי"; try context.save()
        XCTAssertEqual(Ledger(context: context).entry(id: e.id)?.title, "אחרי")
        try LedgerService(context: context).delete(e)
        XCTAssertNil(Ledger(context: context).entry(id: e.id))
    }

    func testBackupRoundTripAndTamperDetection() throws {
        context.insert(Account(name: "בנק", kind: .bank, scope: .personal, knownBalance: Money(shekels: 1234)))
        _ = try service().ingestApplePay(amountText: "12.34", merchant: "x", cardLabel: nil)
        let url = try BackupService(context: context).exportBackup()
        let data = try Data(contentsOf: url)
        let file = try BackupService.validate(data: data)
        XCTAssertEqual(file.payload.entries.count, 1)

        // שינוי ידני בקובץ → נכשל בבדיקת התקינות
        let tampered = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "1234", with: "9999")
        XCTAssertThrowsError(try BackupService.validate(data: tampered.data(using: .utf8)!))

        // שחזור לקונטיינר אחר
        let other = Persistence.makeContainer(inMemory: true)
        try BackupService(context: other.mainContext).restore(file)
        let l = Ledger(context: other.mainContext)
        XCTAssertEqual(l.entries().count, 1)
        XCTAssertEqual(l.accounts().first?.knownBalance, Money(shekels: 1234))
        XCTAssertEqual(l.categories().count, Ledger(context: context).categories().count)
    }
}
