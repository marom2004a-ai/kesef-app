import Foundation

/// בניית בקשת "הוספת מסמך" ל-morning (חשבונית ירוקה) — POST /documents.
/// מבוסס על המפרט הרשמי: developers.morning.co/docs/openapi.bundled.json
public enum MorningDocType: Int, CaseIterable, Sendable, Identifiable {
    /// חשבונית מס / קבלה — לעוסק מורשה שקיבל תשלום
    case taxInvoiceReceipt = 320
    /// קבלה בלבד (למשל לעוסק פטור, או על חשבונית שכבר הופקה)
    case receipt = 400
    /// חשבונית מס (בלי קבלה — כשהתשלום עוד לא התקבל)
    case taxInvoice = 305
    /// חשבון עסקה / דרישת תשלום (לא מסמך מס)
    case proforma = 300
    /// חשבונית זיכוי — מבטלת חשבונית מס / חשבונית מס-קבלה
    case creditInvoice = 330
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .taxInvoiceReceipt: return "חשבונית מס / קבלה"
        case .receipt: return "קבלה"
        case .taxInvoice: return "חשבונית מס"
        case .proforma: return "חשבון עסקה (דרישת תשלום)"
        case .creditInvoice: return "חשבונית זיכוי"
        }
    }
    /// האם המסמך מתעד תשלום שהתקבל (ולכן נרשמת הכנסה מאושרת)
    public var recordsPayment: Bool { self == .taxInvoiceReceipt || self == .receipt }
    /// האם אפשר לבטל את המסמך בחשבונית זיכוי
    public var isCancellableByCredit: Bool { self == .taxInvoiceReceipt || self == .taxInvoice }
    /// סוגים שמופיעים בבחירת מסמך חדש (בלי זיכוי — הוא נוצר רק מביטול)
    public static var issuable: [MorningDocType] { [.taxInvoiceReceipt, .receipt, .taxInvoice, .proforma] }
}

public enum MorningPaymentMethod: String, CaseIterable, Sendable, Identifiable {
    case cash, bit, paybox, bankTransfer, cheque, creditCard, applePay, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .cash: return "מזומן"
        case .bit: return "ביט"
        case .paybox: return "PayBox"
        case .bankTransfer: return "העברה בנקאית"
        case .cheque: return "צ׳ק"
        case .creditCard: return "כרטיס אשראי"
        case .applePay: return "Apple Pay"
        case .other: return "אחר"
        }
    }
    /// PaymentGroup: 1 מזומן, 2 צ׳ק, 3 אשראי, 4 העברה, 10 אפליקציית תשלום, 11 אחר
    var paymentType: Int {
        switch self {
        case .cash: return 1
        case .cheque: return 2
        case .creditCard: return 3
        case .bankTransfer: return 4
        case .bit, .paybox, .applePay: return 10
        case .other: return 11
        }
    }
    /// PaymentAppType: 1 Bit, 3 PayBox, 6 Apple Pay
    var appType: Int? {
        switch self {
        case .bit: return 1
        case .paybox: return 3
        case .applePay: return 6
        default: return nil
        }
    }
    /// אמצעי התשלום המקביל באפליקציה
    public var ledgerMethod: PaymentMethod {
        switch self {
        case .cash: return .cash
        case .bit, .paybox: return .bit
        case .bankTransfer: return .bankTransfer
        case .cheque: return .check
        case .creditCard: return .creditCard
        case .applePay: return .applePay
        case .other: return .other
        }
    }
}

extension MorningPaymentMethod {
    /// האם יש פרטי בנק לאמצעי הזה (צ׳ק / העברה)
    public var hasBankDetails: Bool { self == .cheque || self == .bankTransfer }
}

/// פרטי בנק לתשלום בצ׳ק או בהעברה בנקאית — מופיעים על הקבלה
public struct PaymentBankDetails: Sendable, Hashable {
    public var bankName: String
    public var bankBranch: String
    public var bankAccount: String
    /// מספר הצ׳ק (רק בצ׳ק)
    public var chequeNumber: String
    /// אסמכתא של ההעברה / הצ׳ק — מופיעה בהערות המסמך
    public var reference: String
    public init(bankName: String = "", bankBranch: String = "", bankAccount: String = "", chequeNumber: String = "", reference: String = "") {
        self.bankName = bankName; self.bankBranch = bankBranch; self.bankAccount = bankAccount; self.chequeNumber = chequeNumber
        self.reference = reference
    }
}

public struct MorningDocumentDraft: Sendable {
    /// חשבונית זיכוי שמבטלת מסמך קיים (מאותו לקוח, אותו סכום ותיאור)
    public static func cancellation(ofDocumentID id: String, originalType: MorningDocType, clientName: String, clientEmail: String?,
                                    itemDescription: String, amountIncludingVAT: Money, vatExempt: Bool,
                                    payment: MorningPaymentMethod, date: Date) -> MorningDocumentDraft {
        var d = MorningDocumentDraft(type: .creditInvoice, clientName: clientName, clientEmail: clientEmail,
                                     itemDescription: "ביטול: " + itemDescription, amountIncludingVAT: amountIncludingVAT,
                                     vatExempt: vatExempt, payment: payment, date: date)
        d.linkedDocumentIDs = [id]
        d.linkType = "cancel"
        d.includeRefundPayment = originalType.recordsPayment
        return d
    }

    public var type: MorningDocType
    public var clientName: String
    public var clientEmail: String?
    public var clientPhone: String?
    public var clientTaxId: String?
    public var itemDescription: String
    /// הסכום ששולם בפועל, כולל מע״מ
    public var amountIncludingVAT: Money
    /// עוסק פטור: המחיר ללא מע״מ
    public var vatExempt: Bool
    public var payment: MorningPaymentMethod
    public var date: Date
    public var remarks: String?
    public var bankDetails: PaymentBankDetails?
    /// מסמכים מקושרים (למשל המסמך שמבוטל) ואופי הקישור: "cancel" / "link"
    public var linkedDocumentIDs: [String] = []
    public var linkType: String?
    /// בחשבונית זיכוי שמבטלת חשבונית מס-קבלה: לכלול שורת החזר תשלום
    public var includeRefundPayment: Bool = false

    public init(type: MorningDocType, clientName: String, clientEmail: String? = nil, clientPhone: String? = nil,
                clientTaxId: String? = nil, itemDescription: String, amountIncludingVAT: Money, vatExempt: Bool = false,
                payment: MorningPaymentMethod, date: Date, remarks: String? = nil, bankDetails: PaymentBankDetails? = nil) {
        self.bankDetails = bankDetails
        self.type = type; self.clientName = clientName; self.clientEmail = clientEmail; self.clientPhone = clientPhone
        self.clientTaxId = clientTaxId; self.itemDescription = itemDescription; self.amountIncludingVAT = amountIncludingVAT
        self.vatExempt = vatExempt; self.payment = payment; self.date = date; self.remarks = remarks
    }

    public enum ValidationError: Error, Equatable { case missingClient, missingDescription, invalidAmount, invalidEmail, missingChequeNumber }

    public func validate() throws {
        if clientName.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.missingClient }
        if itemDescription.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.missingDescription }
        if !amountIncludingVAT.isPositive { throw ValidationError.invalidAmount }
        if let e = clientEmail?.trimmingCharacters(in: .whitespaces), !e.isEmpty,
           e.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil { throw ValidationError.invalidEmail }
        if type.recordsPayment && payment == .cheque,
           (bankDetails?.chequeNumber.trimmingCharacters(in: .whitespaces) ?? "").isEmpty { throw ValidationError.missingChequeNumber }
    }

    static func isoDay(_ d: Date, _ cal: FinanceCalendar) -> String {
        let c = cal.calendar.dateComponents([.year, .month, .day], from: d)
        func pad(_ n: Int?) -> String { let s = String(n ?? 0); return s.count < 2 ? "0" + s : s }
        return "\(c.year ?? 0)-\(pad(c.month))-\(pad(c.day))"
    }

    /// גוף הבקשה כ-JSON (מילון). סכומים כ-NSDecimalNumber — מדויק, בלי Double.
    public func requestBody(calendar cal: FinanceCalendar = .israel) -> [String: Any] {
        let price = NSDecimalNumber(decimal: amountIncludingVAT.decimalValue)
        var client: [String: Any] = ["name": clientName.trimmingCharacters(in: .whitespaces), "add": true]
        if let e = clientEmail?.trimmingCharacters(in: .whitespaces), !e.isEmpty { client["emails"] = [e] }
        if let p = clientPhone?.trimmingCharacters(in: .whitespaces), !p.isEmpty { client["mobile"] = p }
        if let t = clientTaxId?.trimmingCharacters(in: .whitespaces), !t.isEmpty { client["taxId"] = t }

        var body: [String: Any] = [
            "type": type.rawValue,
            "lang": "he",
            "currency": "ILS",
            // 0 = לפי סוג העסק, 1 = פטור
            "vatType": vatExempt ? 1 : 0,
            "date": Self.isoDay(date, cal),
            "client": client,
            "income": [[
                "description": itemDescription.trimmingCharacters(in: .whitespaces),
                "quantity": 1,
                "price": price,
                "currency": "ILS",
                // 1 = המחיר כולל מע״מ, 2 = פטור ממע״מ
                "vatType": vatExempt ? 2 : 1
            ] as [String: Any]]
        ]
        if type.recordsPayment || (type == .creditInvoice && includeRefundPayment) {
            var p: [String: Any] = ["date": Self.isoDay(date, cal), "type": payment.paymentType, "price": price, "currency": "ILS"]
            if let app = payment.appType { p["appType"] = app }
            if payment.hasBankDetails, let b = bankDetails {
                func put(_ key: String, _ v: String) {
                    let t = v.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { p[key] = t }
                }
                put("bankName", b.bankName)
                put("bankBranch", b.bankBranch)
                put("bankAccount", b.bankAccount)
                if payment == .cheque { put("chequeNum", b.chequeNumber) }
            }
            body["payment"] = [p]
        }
        if !linkedDocumentIDs.isEmpty {
            body["linkedDocumentIds"] = linkedDocumentIDs
            if let linkType { body["linkType"] = linkType }
        }
        var notes: [String] = []
        if type.recordsPayment, payment.hasBankDetails,
           let ref = bankDetails?.reference.trimmingCharacters(in: .whitespaces), !ref.isEmpty { notes.append("אסמכתא: \(ref)") }
        if let r = remarks?.trimmingCharacters(in: .whitespaces), !r.isEmpty { notes.append(r) }
        if !notes.isEmpty { body["remarks"] = notes.joined(separator: "\n") }
        return body
    }
}
