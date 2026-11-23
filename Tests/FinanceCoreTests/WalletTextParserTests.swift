import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

/// הפורמט המדויק ש-iOS שולח כטקסט לא מתועד — בודקים כמה צורות סבירות, ושבמקרה של ספק לא ממציאים סכום.
final class WalletTextParserTests: XCTestCase {
    func testMultilineHebrew() {
        let r = WalletTextParser.parse("סופר יוחננוף נהריה\n‏45.90 ₪\nדיסקונט ••1234")
        XCTAssertEqual(r.amount, ILS(45, 90))
        XCTAssertEqual(r.merchant, "סופר יוחננוף נהריה")
        XCTAssertEqual(r.card, "דיסקונט ••1234")
    }

    func testLabeledEnglish() {
        let r = WalletTextParser.parse("Merchant: Cafe Neto\nAmount: ₪14.00\nCard: Visa ••4821")
        XCTAssertEqual(r.amount, ILS(14))
        XCTAssertEqual(r.merchant, "Cafe Neto")
        XCTAssertEqual(r.card, "Visa ••4821")
    }

    func testSingleLineWithCurrency() {
        let r = WalletTextParser.parse("₪186.40 ב-סופר יוחננוף")
        XCTAssertEqual(r.amount, ILS(186, 40))
        XCTAssertEqual(r.merchant, "ב-סופר יוחננוף")
    }

    func testPlainDecimalLine() {
        let r = WalletTextParser.parse("פז דלק\n250.00")
        XCTAssertEqual(r.amount, ILS(250))
        XCTAssertEqual(r.merchant, "פז דלק")
    }

    func testNoClearAmountStaysEmpty() {
        let r = WalletTextParser.parse("חנות כלשהי 1234")
        XCTAssertNil(r.amount, "מספר בלי סימן מטבע ובלי עשרוניות — לא מנחשים")
        XCTAssertNotNil(r.merchant)
    }

    func testEmpty() {
        XCTAssertEqual(WalletTextParser.parse("  "), WalletTextParser.Result(amount: nil, merchant: nil, card: nil))
    }
}
