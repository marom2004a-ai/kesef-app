import XCTest
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

final class MorningDocumentTests: XCTestCase {
    func draft(_ type: MorningDocType = .taxInvoiceReceipt, payment: MorningPaymentMethod = .bit, email: String? = "client@example.com") -> MorningDocumentDraft {
        MorningDocumentDraft(type: type, clientName: " משפחת לקוח ", clientEmail: email, clientPhone: "050-0000000",
                             itemDescription: "אילוף ביתי — 4 מפגשים", amountIncludingVAT: ILS(1180, 50),
                             payment: payment, date: D(2026, 11, 5))
    }

    func testTaxInvoiceReceiptWithBit() throws {
        let b = draft().requestBody(calendar: cal)
        XCTAssertEqual(b["type"] as? Int, 320)
        XCTAssertEqual(b["lang"] as? String, "he")
        XCTAssertEqual(b["vatType"] as? Int, 0)
        XCTAssertEqual(b["date"] as? String, "2026-11-05")
        let client = b["client"] as! [String: Any]
        XCTAssertEqual(client["name"] as? String, "משפחת לקוח")
        XCTAssertEqual(client["emails"] as? [String], ["client@example.com"])
        XCTAssertEqual(client["mobile"] as? String, "050-0000000")
        let income = (b["income"] as! [[String: Any]])[0]
        XCTAssertEqual(income["vatType"] as? Int, 1, "המחיר כולל מע״מ")
        XCTAssertEqual((income["price"] as? NSDecimalNumber)?.decimalValue, Decimal(string: "1180.5"))
        let pay = (b["payment"] as! [[String: Any]])[0]
        XCTAssertEqual(pay["type"] as? Int, 10)
        XCTAssertEqual(pay["appType"] as? Int, 1)
        XCTAssertEqual((pay["price"] as? NSDecimalNumber)?.decimalValue, Decimal(string: "1180.5"))
        // ה-JSON נוצר בלי שגיאה ומספרים נשארים מדויקים
        let json = String(data: try JSONSerialization.data(withJSONObject: b), encoding: .utf8)!
        XCTAssertTrue(json.contains("1180.5"))
    }

    func testPaymentCodes() {
        func pay(_ m: MorningPaymentMethod) -> [String: Any] { (draft(payment: m).requestBody(calendar: cal)["payment"] as! [[String: Any]])[0] }
        XCTAssertEqual(pay(.cash)["type"] as? Int, 1)
        XCTAssertNil(pay(.cash)["appType"])
        XCTAssertEqual(pay(.creditCard)["type"] as? Int, 3)
        XCTAssertEqual(pay(.bankTransfer)["type"] as? Int, 4)
        XCTAssertEqual(pay(.paybox)["appType"] as? Int, 3)
        XCTAssertEqual(pay(.applePay)["appType"] as? Int, 6)
    }

    func testChequeAndTransferBankDetails() throws {
        var d = draft(payment: .cheque)
        XCTAssertThrowsError(try d.validate()) { XCTAssertEqual($0 as? MorningDocumentDraft.ValidationError, .missingChequeNumber) }
        d.bankDetails = PaymentBankDetails(bankName: "לאומי", bankBranch: "925", bankAccount: "123456", chequeNumber: " 10002 ")
        XCTAssertNoThrow(try d.validate())
        let p = (d.requestBody(calendar: cal)["payment"] as! [[String: Any]])[0]
        XCTAssertEqual(p["type"] as? Int, 2)
        XCTAssertEqual(p["bankName"] as? String, "לאומי")
        XCTAssertEqual(p["bankBranch"] as? String, "925")
        XCTAssertEqual(p["bankAccount"] as? String, "123456")
        XCTAssertEqual(p["chequeNum"] as? String, "10002")
        XCTAssertEqual(MorningPaymentMethod.cheque.ledgerMethod, .check)

        var t = draft(payment: .bankTransfer)
        t.bankDetails = PaymentBankDetails(bankName: "הפועלים", bankBranch: "", bankAccount: "777", chequeNumber: "999", reference: "55512")
        t.remarks = "תודה"
        XCTAssertNoThrow(try t.validate(), "בהעברה הפרטים לא חובה")
        let tp = (t.requestBody(calendar: cal)["payment"] as! [[String: Any]])[0]
        XCTAssertEqual(tp["type"] as? Int, 4)
        XCTAssertEqual(tp["bankName"] as? String, "הפועלים")
        XCTAssertNil(tp["bankBranch"], "שדה ריק לא נשלח")
        XCTAssertNil(tp["chequeNum"], "מספר צ׳ק רק בצ׳ק")
        XCTAssertEqual(t.requestBody(calendar: cal)["remarks"] as? String, "אסמכתא: 55512\nתודה")
        // באמצעי אחר פרטי בנק לא נשלחים
        var c = draft(payment: .cash); c.bankDetails = PaymentBankDetails(bankName: "x")
        XCTAssertNil((c.requestBody(calendar: cal)["payment"] as! [[String: Any]])[0]["bankName"])
    }

    func testInvoiceWithoutPaymentRows() {
        let b = draft(.taxInvoice).requestBody(calendar: cal)
        XCTAssertEqual(b["type"] as? Int, 305)
        XCTAssertNil(b["payment"])
        XCTAssertFalse(MorningDocType.taxInvoice.recordsPayment)
    }

    func testValidation() {
        XCTAssertNoThrow(try draft().validate())
        var d = draft(); d.clientName = "  "
        XCTAssertThrowsError(try d.validate()) { XCTAssertEqual($0 as? MorningDocumentDraft.ValidationError, .missingClient) }
        d = draft(email: "not-an-email")
        XCTAssertThrowsError(try d.validate()) { XCTAssertEqual($0 as? MorningDocumentDraft.ValidationError, .invalidEmail) }
        d = draft(); d.amountIncludingVAT = .zero
        XCTAssertThrowsError(try d.validate())
        XCTAssertNil(draft(email: nil).requestBody(calendar: cal)["client"].flatMap { ($0 as? [String: Any])?["emails"] })
    }
}
