import Foundation
import SwiftData

// מודלים של SwiftData. ערכי enum נשמרים כמחרוזות וסכומים כאגורות (Int64).
// הקשרים בין ישויות נשמרים כמזהי UUID — פשוט, יציב ובטוח למחיקה.

@Model
final class Account {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var scopeRaw: String
    /// יתרה ידועה (פתיחה או עדכון ידני אחרון) ותאריך העדכון
    var knownBalanceMinor: Int64
    var balanceDate: Date
    var billingDay: Int?
    var includeInTotals: Bool
    var isArchived: Bool
    var sortOrder: Int
    var createdAt: Date

    init(name: String, kind: AccountKind, scope: Scope, knownBalance: Money = .zero, balanceDate: Date = .now,
         billingDay: Int? = nil, sortOrder: Int = 0) {
        self.id = UUID(); self.name = name; self.kindRaw = kind.rawValue; self.scopeRaw = scope.rawValue
        self.knownBalanceMinor = knownBalance.minorUnits; self.balanceDate = balanceDate; self.billingDay = billingDay
        self.includeInTotals = true; self.isArchived = false; self.sortOrder = sortOrder; self.createdAt = .now
    }

    var kind: AccountKind { get { AccountKind(rawValue: kindRaw) ?? .other } set { kindRaw = newValue.rawValue } }
    var scope: Scope { get { Scope(rawValue: scopeRaw) ?? .personal } set { scopeRaw = newValue.rawValue } }
    var knownBalance: Money { get { Money(minorUnits: knownBalanceMinor) } set { knownBalanceMinor = newValue.minorUnits } }
}

@Model
final class Category {
    @Attribute(.unique) var id: UUID
    var name: String
    var scopeRaw: String
    var isIncome: Bool
    var isEssential: Bool
    var parentID: UUID?
    var symbol: String
    var isArchived: Bool
    var sortOrder: Int
    /// כמה מהמע״מ בהוצאות בקטגוריה מוכר לקיזוז (נקודות בסיס). רכב: 2/3.
    var vatDeductibleBP: Int = 10_000

    init(name: String, scope: Scope, isIncome: Bool = false, isEssential: Bool = true, parentID: UUID? = nil,
         symbol: String = "tag", sortOrder: Int = 0) {
        self.id = UUID(); self.name = name; self.scopeRaw = scope.rawValue; self.isIncome = isIncome
        self.isEssential = isEssential; self.parentID = parentID; self.symbol = symbol; self.isArchived = false
        self.sortOrder = sortOrder
    }

    var scope: Scope { get { Scope(rawValue: scopeRaw) ?? .personal } set { scopeRaw = newValue.rawValue } }
}

@Model
final class Entry {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var statusRaw: String
    var amountMinor: Int64
    var date: Date
    /// שם בית העסק / תיאור / מקור ההכנסה
    var title: String
    var scopeRaw: String
    var categoryID: UUID?
    var subcategoryID: UUID?
    var accountID: UUID?
    var toAccountID: UUID?
    var paymentMethodRaw: String?
    var isFixed: Bool
    var note: String
    @Attribute(.externalStorage) var receiptImage: Data?
    var sourceRaw: String
    var certaintyRaw: String
    /// פרטים שהגיעו מ-Wallet (לבדיקת כפילויות)
    var cardLabel: String?
    var externalRef: String?
    var rawAmountText: String?
    var possibleDuplicateOfID: UUID?
    var recurringRuleID: UUID?
    var occurrenceDate: Date?
    /// קבוצת פיצול (תשלומים מלקוח / פיצול אישי-עסקי / תשלום חלקי)
    var splitGroupID: UUID?
    var refundOfID: UUID?
    var importFingerprint: String?
    /// מע״מ מדויק מהדוח/החשבונית באגורות (nil = לפי שיעור המע״מ)
    var vatMinor: Int64?
    var createdAt: Date
    var updatedAt: Date
    var confirmedAt: Date?

    init(kind: EntryKind, status: EntryStatus, amount: Money, date: Date, title: String, scope: Scope,
         categoryID: UUID? = nil, accountID: UUID? = nil, source: EntrySource = .manual) {
        self.id = UUID(); self.kindRaw = kind.rawValue; self.statusRaw = status.rawValue
        self.amountMinor = amount.minorUnits; self.date = date; self.title = title; self.scopeRaw = scope.rawValue
        self.categoryID = categoryID; self.accountID = accountID; self.isFixed = false; self.note = ""
        self.sourceRaw = source.rawValue; self.certaintyRaw = Certainty.high.rawValue
        self.createdAt = .now; self.updatedAt = .now
        if status == .confirmed { self.confirmedAt = .now }
    }

    var kind: EntryKind { get { EntryKind(rawValue: kindRaw) ?? .expense } set { kindRaw = newValue.rawValue } }
    var status: EntryStatus { get { EntryStatus(rawValue: statusRaw) ?? .confirmed } set { statusRaw = newValue.rawValue } }
    var scope: Scope { get { Scope(rawValue: scopeRaw) ?? .personal } set { scopeRaw = newValue.rawValue } }
    var amount: Money { get { Money(minorUnits: amountMinor) } set { amountMinor = newValue.minorUnits } }
    var source: EntrySource { get { EntrySource(rawValue: sourceRaw) ?? .manual } set { sourceRaw = newValue.rawValue } }
    var certainty: Certainty { get { Certainty(rawValue: certaintyRaw) ?? .high } set { certaintyRaw = newValue.rawValue } }
    var paymentMethod: PaymentMethod? {
        get { paymentMethodRaw.flatMap(PaymentMethod.init(rawValue:)) }
        set { paymentMethodRaw = newValue?.rawValue }
    }
}

@Model
final class RecurringRule {
    @Attribute(.unique) var id: UUID
    var title: String
    var kindRaw: String
    var amountMinor: Int64
    var isVariableAmount: Bool
    var frequencyRaw: String
    var dayOfMonth: Int
    var startDate: Date
    var endDate: Date?
    var isPaused: Bool
    var scopeRaw: String
    var categoryID: UUID?
    var accountID: UUID?
    var paymentMethodRaw: String?
    /// כמה ימים לפני החיוב לשלוח תזכורת (nil = בלי)
    var remindDaysBefore: Int?
    /// ליצור אוטומטית תנועה ממתינה לאישור ביום החיוב
    var autoCreatePending: Bool
    var note: String
    var createdAt: Date

    init(title: String, kind: EntryKind = .expense, amount: Money, frequency: Frequency = .monthly, dayOfMonth: Int,
         startDate: Date = .now, scope: Scope = .personal) {
        self.id = UUID(); self.title = title; self.kindRaw = kind.rawValue; self.amountMinor = amount.minorUnits
        self.isVariableAmount = false; self.frequencyRaw = frequency.rawValue; self.dayOfMonth = dayOfMonth
        self.startDate = startDate; self.isPaused = false; self.scopeRaw = scope.rawValue; self.remindDaysBefore = 1
        self.autoCreatePending = true; self.note = ""; self.createdAt = .now
    }

    var kind: EntryKind { get { EntryKind(rawValue: kindRaw) ?? .expense } set { kindRaw = newValue.rawValue } }
    var frequency: Frequency { get { Frequency(rawValue: frequencyRaw) ?? .monthly } set { frequencyRaw = newValue.rawValue } }
    var scope: Scope { get { Scope(rawValue: scopeRaw) ?? .personal } set { scopeRaw = newValue.rawValue } }
    var amount: Money { get { Money(minorUnits: amountMinor) } set { amountMinor = newValue.minorUnits } }
    var paymentMethod: PaymentMethod? {
        get { paymentMethodRaw.flatMap(PaymentMethod.init(rawValue:)) }
        set { paymentMethodRaw = newValue?.rawValue }
    }
}

@Model
final class Budget {
    @Attribute(.unique) var id: UUID
    var categoryID: UUID
    var limitMinor: Int64
    /// מניעת התראות חוזרות: החודש והרמה של ההתראה האחרונה
    var lastAlertMonthKey: String?
    var lastAlertLevel: Int

    init(categoryID: UUID, limit: Money) {
        self.id = UUID(); self.categoryID = categoryID; self.limitMinor = limit.minorUnits; self.lastAlertLevel = 0
    }
    var limit: Money { get { Money(minorUnits: limitMinor) } set { limitMinor = newValue.minorUnits } }
}

@Model
final class SavingsGoal {
    @Attribute(.unique) var id: UUID
    var title: String
    var targetMinor: Int64
    var savedMinor: Int64
    var monthlyContributionMinor: Int64
    var targetDate: Date?
    var accountID: UUID?
    var createdAt: Date

    init(title: String, target: Money, monthlyContribution: Money = .zero, targetDate: Date? = nil) {
        self.id = UUID(); self.title = title; self.targetMinor = target.minorUnits; self.savedMinor = 0
        self.monthlyContributionMinor = monthlyContribution.minorUnits; self.targetDate = targetDate; self.createdAt = .now
    }
    var target: Money { get { Money(minorUnits: targetMinor) } set { targetMinor = newValue.minorUnits } }
    var saved: Money { get { Money(minorUnits: savedMinor) } set { savedMinor = newValue.minorUnits } }
    var monthlyContribution: Money { get { Money(minorUnits: monthlyContributionMinor) } set { monthlyContributionMinor = newValue.minorUnits } }
}

@Model
final class ExpenseTemplate {
    @Attribute(.unique) var id: UUID
    var title: String
    var amountMinor: Int64
    var scopeRaw: String
    var categoryID: UUID?
    var accountID: UUID?
    var paymentMethodRaw: String?
    var useCount: Int

    init(title: String, amount: Money, scope: Scope, categoryID: UUID?, accountID: UUID?, paymentMethod: PaymentMethod?) {
        self.id = UUID(); self.title = title; self.amountMinor = amount.minorUnits; self.scopeRaw = scope.rawValue
        self.categoryID = categoryID; self.accountID = accountID; self.paymentMethodRaw = paymentMethod?.rawValue; self.useCount = 0
    }
    var amount: Money { Money(minorUnits: amountMinor) }
    var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
}

/// שיוך שם כרטיס כפי שמגיע מ-Wallet ("Visa 1234") לחשבון באפליקציה. לא נשמר מספר כרטיס מלא.
@Model
final class CardAlias {
    @Attribute(.unique) var id: UUID
    var walletLabel: String
    var accountID: UUID
    init(walletLabel: String, accountID: UUID) {
        self.id = UUID(); self.walletLabel = walletLabel; self.accountID = accountID
    }
}

/// מסמך שהופק דרך morning (או הדגמה) — הארכיון של הקבלות באפליקציה
@Model
final class IssuedDocument {
    @Attribute(.unique) var id: UUID
    /// המזהה ב-morning ("demo-..." בהדגמה)
    var externalID: String
    var number: Int
    var typeRaw: Int
    var clientName: String
    var clientEmail: String
    var itemDescription: String
    var amountMinor: Int64
    var vatMinor: Int64
    var paymentRaw: String
    var date: Date
    var urlString: String?
    var environmentRaw: String
    var entryID: UUID?
    var createdAt: Date
    /// מספר חשבונית הזיכוי שביטלה את המסמך (nil = לא בוטל)
    var cancelledByNumber: Int?

    init(externalID: String, number: Int, type: MorningDocType, clientName: String, clientEmail: String,
         itemDescription: String, amount: Money, vat: Money, payment: MorningPaymentMethod, date: Date,
         url: URL?, environment: String) {
        self.id = UUID(); self.externalID = externalID; self.number = number; self.typeRaw = type.rawValue
        self.clientName = clientName; self.clientEmail = clientEmail; self.itemDescription = itemDescription
        self.amountMinor = amount.minorUnits; self.vatMinor = vat.minorUnits; self.paymentRaw = payment.rawValue
        self.date = date; self.urlString = url?.absoluteString; self.environmentRaw = environment; self.createdAt = .now
    }

    var amount: Money { Money(minorUnits: amountMinor) }
    var vat: Money { Money(minorUnits: vatMinor) }
    var type: MorningDocType? { MorningDocType(rawValue: typeRaw) }
    var payment: MorningPaymentMethod? { MorningPaymentMethod(rawValue: paymentRaw) }
    var url: URL? { urlString.flatMap(URL.init(string:)) }
    var isReal: Bool { environmentRaw == "production" }
}

/// לקוח שמור — כדי שבפעם הבאה הכנסה וקבלה יתמלאו לבד (כולל פרטי בנק לצ׳קים/העברות)
@Model
final class Client {
    @Attribute(.unique) var id: UUID
    var name: String
    var email: String
    var phone: String
    var taxId: String
    var bankName: String
    var bankBranch: String
    var bankAccount: String
    var preferredPaymentRaw: String?
    var defaultCategoryID: UUID?
    var defaultDescription: String
    var lastAmountMinor: Int64
    var useCount: Int
    var lastUsedAt: Date
    var note: String
    var createdAt: Date

    init(name: String) {
        self.id = UUID(); self.name = name; self.email = ""; self.phone = ""; self.taxId = ""
        self.bankName = ""; self.bankBranch = ""; self.bankAccount = ""; self.preferredPaymentRaw = nil
        self.defaultCategoryID = nil; self.defaultDescription = ""; self.lastAmountMinor = 0; self.useCount = 0
        self.lastUsedAt = .now; self.note = ""; self.createdAt = .now
    }

    var preferredPayment: MorningPaymentMethod? {
        get { preferredPaymentRaw.flatMap(MorningPaymentMethod.init(rawValue:)) }
        set { preferredPaymentRaw = newValue?.rawValue }
    }
    var lastAmount: Money { Money(minorUnits: lastAmountMinor) }
    var hasBankDetails: Bool { !bankName.isEmpty || !bankAccount.isEmpty }
}

enum KesefSchema {
    static let models: [any PersistentModel.Type] = [
        Account.self, Category.self, Entry.self, RecurringRule.self, Budget.self,
        SavingsGoal.self, ExpenseTemplate.self, CardAlias.self, IssuedDocument.self, Client.self
    ]
}

// MARK: - המרה לצילומי מצב עבור המנועים

extension Entry {
    var snapshot: EntrySnapshot {
        EntrySnapshot(id: id, kind: kind, status: status, amount: amount, date: date, createdAt: createdAt, title: title,
                      scope: scope, categoryID: categoryID, accountID: accountID, toAccountID: toAccountID,
                      recurringRuleID: recurringRuleID, occurrenceDate: occurrenceDate, certainty: certainty, isFixed: isFixed,
                      vatOverride: vatMinor.map { Money(minorUnits: $0) })
    }
}
extension Account {
    var snapshot: AccountSnapshot {
        AccountSnapshot(id: id, name: name, kind: kind, scope: scope, knownBalance: knownBalance, balanceDate: balanceDate,
                        billingDay: billingDay, includeInTotals: includeInTotals && !isArchived)
    }
}
extension RecurringRule {
    var snapshot: RecurringSnapshot {
        RecurringSnapshot(id: id, title: title, kind: kind, amount: amount, isVariableAmount: isVariableAmount,
                          frequency: frequency, dayOfMonth: dayOfMonth, startDate: startDate, endDate: endDate,
                          isPaused: isPaused, scope: scope, categoryID: categoryID, accountID: accountID)
    }
}
extension Category {
    var snapshot: CategorySnapshot {
        CategorySnapshot(id: id, name: name, scope: scope, isIncome: isIncome, isEssential: isEssential)
    }
}
extension Budget {
    var snapshot: BudgetSnapshot { BudgetSnapshot(id: id, categoryID: categoryID, limit: limit) }
}
