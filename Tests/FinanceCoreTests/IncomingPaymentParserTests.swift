import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

// הודעות לדוגמה בלבד (שמות וסכומים מומצאים)
final class IncomingPaymentParserTests: XCTestCase {
    func testBitStyleMessage() {
        let r = IncomingPaymentParser.parse("ישראל ישראלי העביר לך 250 ₪ בביט")
        XCTAssertEqual(r.amount, ILS(250))
        XCTAssertEqual(r.payer, "ישראל ישראלי")
        XCTAssertEqual(r.source, "Bit")
    }

    func testCurrencyFirstAndFemaleVerb() {
        let r = IncomingPaymentParser.parse("דנה כהן שלחה לך ₪1,180.50 באפליקציית Bit")
        XCTAssertEqual(r.amount, ILS(1180, 50))
        XCTAssertEqual(r.payer, "דנה כהן")
    }

    func testFromPatternAndSum() {
        let r = IncomingPaymentParser.parse("קיבלת העברה בסך 900 ש״ח מאת משפחת לוי.")
        XCTAssertEqual(r.amount, ILS(900))
        XCTAssertEqual(r.payer, "משפחת לוי")
        XCTAssertEqual(r.source, "העברה בנקאית")
    }

    func testNoCurrencyNoAmount() {
        let r = IncomingPaymentParser.parse("קוד האימות שלך הוא 482913")
        XCTAssertNil(r.amount, "מספר בלי סימן מטבע הוא לא סכום")
        XCTAssertNil(r.payer)
    }
}
