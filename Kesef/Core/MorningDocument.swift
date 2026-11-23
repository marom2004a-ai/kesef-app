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
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .taxInvoiceReceipt: return "חשבונית מס / קבלה"
        case .receipt: return "קבלה"
        case .taxInvoice: return "חשבונית מס"
        case .proforma: return "חשבון עסקה (דרישת תשלום)"
        }
    }
    /// האם המסמך מתעד תשלום שהתקבל (ולכן נרשמת הכנסה מאושרת)
    public var recordsPayment: Bool { self == .taxInvoiceReceipt || self == .receipt }
}

public enum MorningPaymentMethod: String, CaseIterable, Sendable, Identifiable {
    case cash, bit, paybox, bankTransfer, creditCard, applePay, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .cash: return "מזומן"
        case .bit: return "ביט"
        case .paybox: return "PayBox"
        case .bankTransfer: return "העברה בנקאית"
        case .creditCard: return "כרטיס אשראי"
        case .applePay: return "Apple Pay"
        case .other: return "אחר"
        }
    }
    /// PaymentGroup: 1 מזומן, 3 אשראי, 4 העברה, 10 אפליקציית תשלום, 11 אחר
    var paymentType: Int {
        switch self {
        case .cash: return 1
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
        case .creditCard: return .creditCard
        case .applePay: return .applePay
        case .other: return .other
        }
    }
}

public struct MorningDocumentDraft: Sendable {
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

    public init(type: MorningDocType, clientName: String, clientEmail: String? = nil, clientPhone: String? = nil,
                clientTaxId: String? = nil, itemDescription: String, amountIncludingVAT: Money, vatExempt: Bool = false,
                payment: MorningPaymentMethod, date: Date, remarks: String? = nil) {
        self.type = type; self.clientName = clientName; self.clientEmail = clientEmail; self.clientPhone = clientPhone
        self.clientTaxId = clientTaxId; self.itemDescription = itemDescription; self.amountIncludingVAT = amountIncludingVAT
        self.vatExempt = vatExempt; self.payment = payment; self.date = date; self.remarks = remarks
    }

    public enum ValidationError: Error, Equatable { case missingClient, missingDescription, invalidAmount, invalidEmail }

    public func validate() throws {
        if clientName.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.missingClient }
        if itemDescription.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.missingDescription }
        if !amountIncludingVAT.isPositive { throw ValidationError.invalidAmount }
        if let e = clientEmail?.trimmingCharacters(in: .whitespaces), !e.isEmpty,
           e.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil { throw ValidationError.invalidEmail }
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
        if type.recordsPayment {
            var p: [String: Any] = ["date": Self.isoDay(date, cal), "type": payment.paymentType, "price": price, "currency": "ILS"]
            if let app = payment.appType { p["appType"] = app }
            body["payment"] = [p]
        }
        if let r = remarks?.trimmingCharacters(in: .whitespaces), !r.isEmpty { body["remarks"] = r }
        return body
    }
}
