import Foundation

// MARK: - סוגים בסיסיים

public enum Scope: String, Codable, CaseIterable, Sendable, Identifiable {
    case personal, business
    public var id: String { rawValue }
    public var label: String { self == .personal ? "אישי" : "עסקי" }
    public var expenseLabel: String { self == .personal ? "הוצאה אישית" : "הוצאה עסקית" }
}

/// סוג התנועה. רק income / expense / refund נכנסים לרווח והפסד.
/// העברות, סילוק כרטיס, משיכות בעלים ותשלום לשותף משנים יתרות אבל אינם "הוצאה" — כך נמנעת ספירה כפולה.
public enum EntryKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case income, expense, refund, transfer, cardPayment, ownerDraw, partnerPayout, taxPayment
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .income: return "הכנסה"
        case .expense: return "הוצאה"
        case .refund: return "זיכוי / החזר"
        case .transfer: return "העברה בין חשבונות"
        case .cardPayment: return "סילוק כרטיס אשראי"
        case .ownerDraw: return "משיכת בעלים"
        case .partnerPayout: return "תשלום לשותף"
        case .taxPayment: return "תשלום מע״מ / מס"
        }
    }
    public var isProfitAndLoss: Bool { self == .income || self == .expense || self == .refund }
    public var needsDestinationAccount: Bool { self == .transfer || self == .cardPayment || self == .ownerDraw }
}

public enum EntryStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    /// ממתינה לאישור (Apple Pay / חיוב קבוע אוטומטי)
    case pendingReview
    /// התקבלה / אושרה — משפיעה על היתרה
    case confirmed
    /// הוצאה מתוכננת או הכנסה צפויה — לא משפיעה על היתרה, רק על התחזית
    case planned
    case cancelled
    public var id: String { rawValue }

    public func label(for kind: EntryKind) -> String {
        switch (self, kind) {
        case (.pendingReview, _): return "ממתינה לאישור"
        case (.confirmed, .income): return "התקבלה בפועל"
        case (.confirmed, _): return "מאושרת"
        case (.planned, .income): return "צפויה"
        case (.planned, _): return "מתוכננת"
        case (.cancelled, _): return "בוטלה"
        }
    }
}

public enum AccountKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case bank, businessBank, cash, creditCard, savings, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bank: return "חשבון בנק אישי"
        case .businessBank: return "חשבון עסקי"
        case .cash: return "מזומן"
        case .creditCard: return "כרטיס אשראי"
        case .savings: return "חיסכון / פיקדון"
        case .other: return "אחר"
        }
    }
    public var symbol: String {
        switch self {
        case .bank: return "building.columns"
        case .businessBank: return "briefcase"
        case .cash: return "banknote"
        case .creditCard: return "creditcard"
        case .savings: return "lock.square"
        case .other: return "tray"
        }
    }
    /// כסף זמין לשימוש (נכלל ב"יתרה נוכחית"). כרטיס אשראי הוא חוב; חיסכון מוצג בנפרד.
    public var isLiquid: Bool { self == .bank || self == .businessBank || self == .cash || self == .other }
}

public enum Frequency: String, Codable, CaseIterable, Sendable, Identifiable {
    case weekly, monthly, bimonthly, quarterly, yearly
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .weekly: return "שבועי"
        case .monthly: return "חודשי"
        case .bimonthly: return "דו-חודשי"
        case .quarterly: return "רבעוני"
        case .yearly: return "שנתי"
        }
    }
    var monthStep: Int? {
        switch self {
        case .weekly: return nil
        case .monthly: return 1
        case .bimonthly: return 2
        case .quarterly: return 3
        case .yearly: return 12
        }
    }
    /// מקדם להמרה לסכום חודשי שווה-ערך
    public var monthlyFactor: Decimal {
        switch self {
        case .weekly: return Decimal(52) / Decimal(12)
        case .monthly: return 1
        case .bimonthly: return Decimal(1) / Decimal(2)
        case .quarterly: return Decimal(1) / Decimal(3)
        case .yearly: return Decimal(1) / Decimal(12)
        }
    }
}

public enum Certainty: String, Codable, CaseIterable, Sendable, Identifiable {
    case high, medium, low
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .high: return "ודאית"
        case .medium: return "סבירה"
        case .low: return "לא בטוחה"
        }
    }
}

public enum EntrySource: String, Codable, CaseIterable, Sendable {
    case manual, applePayShortcut, csvImport, recurring, siri, backup
    public var label: String {
        switch self {
        case .manual: return "הזנה ידנית"
        case .applePayShortcut: return "Apple Pay / Shortcuts"
        case .csvImport: return "ייבוא CSV"
        case .recurring: return "חיוב קבוע"
        case .siri: return "Siri / קיצור דרך"
        case .backup: return "שחזור גיבוי"
        }
    }
}

public enum PaymentMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case creditCard, applePay, bankTransfer, cash, bit, check, standingOrder, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .creditCard: return "כרטיס אשראי"
        case .applePay: return "Apple Pay"
        case .bankTransfer: return "העברה בנקאית"
        case .cash: return "מזומן"
        case .bit: return "ביט / פייבוקס"
        case .check: return "צ׳ק"
        case .standingOrder: return "הוראת קבע"
        case .other: return "אחר"
        }
    }
}

public enum Scenario: String, Codable, CaseIterable, Sendable, Identifiable {
    case conservative, base, optimistic
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .conservative: return "שמרני"
        case .base: return "בסיסי"
        case .optimistic: return "אופטימי"
        }
    }
    func includes(_ c: Certainty) -> Bool {
        switch self {
        case .conservative: return c == .high
        case .base: return c != .low
        case .optimistic: return true
        }
    }
    /// מקדם להוצאות משתנות יומיות (באחוזים)
    var variableSpendingPercent: Int {
        switch self {
        case .conservative: return 120
        case .base: return 100
        case .optimistic: return 80
        }
    }
}

public enum PartnerBasis: String, Codable, CaseIterable, Sendable, Identifiable {
    case profit, revenue
    public var id: String { rawValue }
    public var label: String { self == .profit ? "מהרווח (הכנסות פחות הוצאות עסקיות)" : "מההכנסות העסקיות" }
}

// MARK: - צילומי מצב (Value types) שהמנועים עובדים עליהם — בלי תלות ב-SwiftData

public struct EntrySnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: EntryKind
    public var status: EntryStatus
    /// תמיד חיובי; הכיוון נקבע לפי kind
    public var amount: Money
    public var date: Date
    public var createdAt: Date
    public var title: String
    public var scope: Scope
    public var categoryID: UUID?
    public var accountID: UUID?
    public var toAccountID: UUID?
    public var recurringRuleID: UUID?
    public var occurrenceDate: Date?
    public var certainty: Certainty
    public var isFixed: Bool
    /// סכום מע״מ מדויק מתוך הדוח/החשבונית (אם ידוע). nil = מחושב לפי שיעור המע״מ.
    public var vatOverride: Money?

    public init(id: UUID = UUID(), kind: EntryKind, status: EntryStatus = .confirmed, amount: Money, date: Date,
                createdAt: Date? = nil, title: String = "", scope: Scope = .personal, categoryID: UUID? = nil,
                accountID: UUID? = nil, toAccountID: UUID? = nil, recurringRuleID: UUID? = nil,
                occurrenceDate: Date? = nil, certainty: Certainty = .high, isFixed: Bool = false, vatOverride: Money? = nil) {
        self.id = id; self.kind = kind; self.status = status; self.amount = amount; self.date = date
        self.createdAt = createdAt ?? date; self.title = title; self.scope = scope; self.categoryID = categoryID
        self.accountID = accountID; self.toAccountID = toAccountID; self.recurringRuleID = recurringRuleID
        self.occurrenceDate = occurrenceDate; self.certainty = certainty; self.isFixed = isFixed
        self.vatOverride = vatOverride
    }
}

public struct AccountSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: AccountKind
    public var scope: Scope
    /// יתרה ידועה נכון ל-balanceDate (יתרת פתיחה או עדכון ידני אחרון)
    public var knownBalance: Money
    public var balanceDate: Date
    /// יום חיוב בחודש (לכרטיסי אשראי)
    public var billingDay: Int?
    public var includeInTotals: Bool

    public init(id: UUID = UUID(), name: String, kind: AccountKind, scope: Scope = .personal, knownBalance: Money = .zero,
                balanceDate: Date, billingDay: Int? = nil, includeInTotals: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.scope = scope; self.knownBalance = knownBalance
        self.balanceDate = balanceDate; self.billingDay = billingDay; self.includeInTotals = includeInTotals
    }
}

public struct RecurringSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// income או expense בלבד
    public var kind: EntryKind
    public var amount: Money
    public var isVariableAmount: Bool
    public var frequency: Frequency
    public var dayOfMonth: Int
    public var startDate: Date
    public var endDate: Date?
    public var isPaused: Bool
    public var scope: Scope
    public var categoryID: UUID?
    public var accountID: UUID?

    public init(id: UUID = UUID(), title: String, kind: EntryKind = .expense, amount: Money, isVariableAmount: Bool = false,
                frequency: Frequency = .monthly, dayOfMonth: Int, startDate: Date, endDate: Date? = nil,
                isPaused: Bool = false, scope: Scope = .personal, categoryID: UUID? = nil, accountID: UUID? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.amount = amount; self.isVariableAmount = isVariableAmount
        self.frequency = frequency; self.dayOfMonth = dayOfMonth; self.startDate = startDate; self.endDate = endDate
        self.isPaused = isPaused; self.scope = scope; self.categoryID = categoryID; self.accountID = accountID
    }

    public var monthlyEquivalent: Money { amount.multiplied(by: frequency.monthlyFactor) }
}

public struct CategorySnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var scope: Scope
    public var isIncome: Bool
    public var isEssential: Bool
    public init(id: UUID = UUID(), name: String, scope: Scope, isIncome: Bool = false, isEssential: Bool = true) {
        self.id = id; self.name = name; self.scope = scope; self.isIncome = isIncome; self.isEssential = isEssential
    }
}

public struct BudgetSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var categoryID: UUID
    public var limit: Money
    public init(id: UUID = UUID(), categoryID: UUID, limit: Money) {
        self.id = id; self.categoryID = categoryID; self.limit = limit
    }
}

public struct PartnerSettings: Hashable, Sendable {
    public var name: String
    /// נקודות בסיס: 5000 = 50%
    public var shareBasisPoints: Int
    public var basis: PartnerBasis
    public init(name: String, shareBasisPoints: Int, basis: PartnerBasis) {
        self.name = name; self.shareBasisPoints = shareBasisPoints; self.basis = basis
    }
    public var isActive: Bool { shareBasisPoints > 0 }
}
