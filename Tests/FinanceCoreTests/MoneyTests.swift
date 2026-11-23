import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class MoneyTests: XCTestCase {
    func testArithmeticIsExact() {
        // 0.1 + 0.2 ב-Double נותן 0.30000000000000004 — כאן חייב להיות 30 אגורות בדיוק
        XCTAssertEqual(Money(minorUnits: 10) + Money(minorUnits: 20), Money(minorUnits: 30))
        XCTAssertEqual(Money(decimal: Decimal(string: "0.1")! + Decimal(string: "0.2")!), Money(minorUnits: 30))
        XCTAssertEqual(ILS(10) - ILS(12, 50), Money(minorUnits: -250))
        XCTAssertEqual([ILS(1), ILS(2), ILS(3, 33)].sum(), Money(minorUnits: 633))
    }

    func testDecimalRounding() {
        XCTAssertEqual(Money(decimal: Decimal(string: "12.345")!), Money(minorUnits: 1235))
        XCTAssertEqual(Money(decimal: Decimal(string: "12.344")!), Money(minorUnits: 1234))
        XCTAssertEqual(Money(decimal: Decimal(string: "-12.345")!), Money(minorUnits: -1235))
    }

    func testBasisPoints() {
        XCTAssertEqual(ILS(1000).multiplied(byBasisPoints: 5000), ILS(500))
        XCTAssertEqual(Money(minorUnits: 333).multiplied(byBasisPoints: 5000), Money(minorUnits: 167)) // 166.5 → 167
        XCTAssertEqual(Money(minorUnits: -333).multiplied(byBasisPoints: 5000), Money(minorUnits: -167))
        XCTAssertEqual(Money.ratioBasisPoints(ILS(80), of: ILS(100)), 8000)
        XCTAssertNil(Money.ratioBasisPoints(ILS(80), of: .zero))
    }

    func testSplitSumsToOriginal() {
        let parts = ILS(100).split(into: 3)
        XCTAssertEqual(parts, [Money(minorUnits: 3334), Money(minorUnits: 3333), Money(minorUnits: 3333)])
        XCTAssertEqual(parts.sum(), ILS(100))
        XCTAssertEqual(Money(minorUnits: -100).split(into: 3).sum(), Money(minorUnits: -100))
    }

    func testFormatting() {
        XCTAssertEqual(MoneyFormat.string(ILS(1234, 50)), "\u{200E}1,234.50 ₪")
        XCTAssertEqual(MoneyFormat.string(ILS(1_000_000)), "\u{200E}1,000,000 ₪")
        XCTAssertEqual(MoneyFormat.string(Money(minorUnits: -5)), "\u{200E}-0.05 ₪")
        XCTAssertEqual(MoneyFormat.editString(Money(minorUnits: 1205)), "12.05")
    }

    func testAmountParser() {
        XCTAssertEqual(AmountParser.parse("₪45.90"), ILS(45, 90))
        XCTAssertEqual(AmountParser.parse("45.90 ₪"), ILS(45, 90))
        XCTAssertEqual(AmountParser.parse("45,90"), ILS(45, 90))
        XCTAssertEqual(AmountParser.parse("1,234.50"), ILS(1234, 50))
        XCTAssertEqual(AmountParser.parse("1.234,50"), ILS(1234, 50))
        XCTAssertEqual(AmountParser.parse("1,234"), ILS(1234))
        XCTAssertEqual(AmountParser.parse("ILS 12"), ILS(12))
        XCTAssertEqual(AmountParser.parse("(120.00)"), ILS(-120))
        XCTAssertEqual(AmountParser.parse("120.00-"), ILS(-120))
        XCTAssertEqual(AmountParser.parse("−7.5"), Money(minorUnits: -750))
        XCTAssertEqual(AmountParser.parse("0.005"), Money(minorUnits: 1))
        XCTAssertNil(AmountParser.parse(""))
        XCTAssertNil(AmountParser.parse("₪"))
        XCTAssertNil(AmountParser.parse("אין סכום"))
    }
}
