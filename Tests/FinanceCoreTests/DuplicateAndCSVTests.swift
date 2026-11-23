import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class DuplicateDetectorTests: XCTestCase {
    let t0 = D(2026, 11, 10, 13, 0)

    func candidate(_ amount: Money?, _ merchant: String?, _ card: String?, at: Date, ext: String? = nil) -> PurchaseCandidate {
        PurchaseCandidate(id: UUID(), amount: amount, merchant: merchant, cardLabel: card, externalID: ext, receivedAt: at)
    }

    func testRerunWithinWindowIsBlocked() {
        let c = candidate(ILS(42, 90), "סופר כהן", "Visa 1234", at: t0)
        let incoming = IncomingPurchase(amount: ILS(42, 90), merchant: "  סופר  כהן ", cardLabel: "visa 1234", receivedAt: t0.addingTimeInterval(40))
        XCTAssertEqual(DuplicateDetector.check(incoming, against: [c]), .rerun(of: c.id))
    }

    func testSameIDIsAlwaysRerun() {
        let c = candidate(ILS(10), "קפה", nil, at: t0, ext: "abc")
        let incoming = IncomingPurchase(amount: ILS(99), merchant: "אחר", cardLabel: nil, externalID: "abc", receivedAt: t0.addingTimeInterval(86400))
        XCTAssertEqual(DuplicateDetector.check(incoming, against: [c]), .rerun(of: c.id))
    }

    func testSimilarLaterPurchaseIsCreatedButFlagged() {
        // שני קפה באותו סכום בהפרש שעה — אמיתי, אבל מסומן לבדיקה
        let c = candidate(ILS(14), "Cafe Neto", "Visa", at: t0)
        let incoming = IncomingPurchase(amount: ILS(14), merchant: "CAFE NETO", cardLabel: "Visa", receivedAt: t0.addingTimeInterval(3600))
        XCTAssertEqual(DuplicateDetector.check(incoming, against: [c]), .similar(to: c.id))
    }

    func testDifferentAmountOrCardIsUnique() {
        let c = candidate(ILS(14), "Cafe", "Visa", at: t0)
        XCTAssertEqual(DuplicateDetector.check(IncomingPurchase(amount: ILS(15), merchant: "Cafe", cardLabel: "Visa", receivedAt: t0.addingTimeInterval(30)), against: [c]), .unique)
        XCTAssertEqual(DuplicateDetector.check(IncomingPurchase(amount: ILS(14), merchant: "Cafe", cardLabel: "Mastercard", receivedAt: t0.addingTimeInterval(30)), against: [c]), .unique)
        XCTAssertEqual(DuplicateDetector.check(IncomingPurchase(amount: ILS(14), merchant: "Cafe", cardLabel: "Visa", receivedAt: t0.addingTimeInterval(8 * 3600)), against: [c]), .unique)
    }

    func testIncompletePurchasesStillDetectRerun() {
        let c = candidate(nil, nil, "Visa", at: t0)
        XCTAssertEqual(DuplicateDetector.check(IncomingPurchase(amount: nil, merchant: nil, cardLabel: "Visa", receivedAt: t0.addingTimeInterval(20)), against: [c]), .rerun(of: c.id))
        XCTAssertEqual(DuplicateDetector.check(IncomingPurchase(amount: nil, merchant: nil, cardLabel: "Visa", receivedAt: t0.addingTimeInterval(3600)), against: [c]), .unique)
    }
}

final class CSVTests: XCTestCase {
    func testParserHandlesQuotesBOMAndDelimiters() {
        let text = "\u{FEFF}תאריך,תיאור,סכום\r\n05/11/2026,\"שופרסל, נהריה\",-123.40\r\n06/11/2026,\"אמר \"\"שלום\"\"\",50\r\n"
        let rows = CSVParser.parse(text)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][1], "שופרסל, נהריה")
        XCTAssertEqual(rows[2][1], "אמר \"שלום\"")
        XCTAssertEqual(CSVParser.detectDelimiter("a;b;c\n1;2;3"), ";")
        XCTAssertEqual(CSVParser.parse("a\tb\n1\t2").last, ["1", "2"])
    }

    func testDateParsing() {
        XCTAssertEqual(CSVImportEngine.parseDate("05/11/2026").map { cal.day($0) }, 5)
        XCTAssertEqual(CSVImportEngine.parseDate("5.11.26").map { cal.calendar.component(.year, from: $0) }, 2026)
        XCTAssertEqual(CSVImportEngine.parseDate("2026-11-05").map { cal.day($0) }, 5)
        XCTAssertEqual(CSVImportEngine.parseDate("11/05/2026", dayFirst: false).map { cal.day($0) }, 5)
        XCTAssertNil(CSVImportEngine.parseDate("31/02/2026"))
        XCTAssertNil(CSVImportEngine.parseDate("hello"))
    }

    func testMappingGuessAndRows() {
        let table = CSVParser.parse("תאריך עסקה,שם בית העסק,סכום חיוב\n01/11/2026,רמי לוי,250.00\n02/11/2026,סה\"כ,250.00\n")
        var m = CSVImportEngine.guessMapping(table)
        XCTAssertTrue(m.hasHeader)
        XCTAssertEqual(m.dateColumn, 0); XCTAssertEqual(m.descriptionColumn, 1); XCTAssertEqual(m.amountColumn, 2)
        m.positiveIsExpense = true
        let rows = CSVImportEngine.rows(from: table, mapping: m)
        XCTAssertEqual(rows[0].signedAmount, ILS(-250))
        XCTAssertTrue(rows[0].isValid)
        XCTAssertFalse(rows[1].isValid) // שורת סיכום
    }

    func testDebitCreditColumns() {
        let table = CSVParser.parse("תאריך,תיאור,חובה,זכות\n01/11/2026,העברה,,1000\n02/11/2026,חשמל,320.5,\n")
        let m = CSVImportEngine.guessMapping(table)
        XCTAssertNil(m.amountColumn)
        let rows = CSVImportEngine.rows(from: table, mapping: m)
        XCTAssertEqual(rows.map(\.signedAmount), [ILS(1000), Money(minorUnits: -32050)])
    }

    func testDuplicateMarkingUsesMultiset() {
        let acc = UUID()
        let table = CSVParser.parse("תאריך,תיאור,סכום\n01/11/2026,קפה,-14\n01/11/2026,קפה,-14\n03/11/2026,דלק,-200\n")
        let rows = CSVImportEngine.rows(from: table, mapping: CSVImportEngine.guessMapping(table))
        let existing = [CSVImportEngine.fingerprint(date: D(2026, 11, 1, 18), signedAmount: ILS(-14), description: "קפה", accountID: acc)]
        let marked = CSVImportEngine.markDuplicates(rows, existingFingerprints: existing, accountID: acc)
        XCTAssertEqual(marked.map(\.isDuplicate), [true, false, false])
        // ייבוא חוזר של אותו קובץ אחרי שהכול יובא — הכול כפול
        let all = rows.map { CSVImportEngine.fingerprint(date: $0.date!, signedAmount: $0.signedAmount!, description: $0.description, accountID: acc) }
        XCTAssertEqual(CSVImportEngine.markDuplicates(rows, existingFingerprints: all, accountID: acc).map(\.isDuplicate), [true, true, true])
    }

    func testExportEscapesAndHasBOM() {
        let row = CSVExporter.Row(date: D(2026, 11, 5), kind: "הוצאה", status: "מאושרת", title: "ספק, בע\"מ", amount: ILS(12, 5),
                                  scope: "עסקי", category: "ציוד", account: "עסקי", paymentMethod: "אשראי", source: "ידני", note: "")
        let csv = CSVExporter.csv([row], calendar: cal)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(csv.contains("05/11/2026,הוצאה,מאושרת,\"ספק, בע\"\"מ\",12.05,"))
        // הקובץ שיוצא נקרא חזרה זהה
        XCTAssertEqual(CSVParser.parse(csv)[1][3], "ספק, בע\"מ")
    }
}
