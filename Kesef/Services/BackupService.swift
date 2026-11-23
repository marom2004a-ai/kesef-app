import Foundation
import SwiftData
import CryptoKit

/// גיבוי מלא לקובץ JSON עם סכום ביקורת SHA-256, ושחזור שבודק תקינות לפני שהוא נוגע בנתונים.
/// הקובץ אינו מוצפן — הוא נשמר היכן שהמשתמש בוחר (Files / iCloud Drive). זה מוצג למשתמש במסך הגיבוי.
@MainActor
struct BackupService {
    let context: ModelContext
    static let formatVersion = 1

    struct AccountDTO: Codable { var id: UUID; var name: String; var kind: String; var scope: String; var knownBalance: Int64
        var balanceDate: Date; var billingDay: Int?; var includeInTotals: Bool; var isArchived: Bool; var sortOrder: Int; var createdAt: Date }
    struct CategoryDTO: Codable { var id: UUID; var name: String; var scope: String; var isIncome: Bool; var isEssential: Bool
        var parentID: UUID?; var symbol: String; var isArchived: Bool; var sortOrder: Int; var vatDeductibleBP: Int? }
    struct EntryDTO: Codable { var id: UUID; var kind: String; var status: String; var amount: Int64; var date: Date; var title: String
        var scope: String; var categoryID: UUID?; var subcategoryID: UUID?; var accountID: UUID?; var toAccountID: UUID?
        var paymentMethod: String?; var isFixed: Bool; var note: String; var receiptImage: Data?; var source: String
        var certainty: String; var cardLabel: String?; var externalRef: String?; var rawAmountText: String?
        var possibleDuplicateOfID: UUID?; var recurringRuleID: UUID?; var occurrenceDate: Date?; var splitGroupID: UUID?
        var refundOfID: UUID?; var importFingerprint: String?; var createdAt: Date; var updatedAt: Date; var confirmedAt: Date?
        var vatMinor: Int64? }
    struct RuleDTO: Codable { var id: UUID; var title: String; var kind: String; var amount: Int64; var isVariableAmount: Bool
        var frequency: String; var dayOfMonth: Int; var startDate: Date; var endDate: Date?; var isPaused: Bool; var scope: String
        var categoryID: UUID?; var accountID: UUID?; var paymentMethod: String?; var remindDaysBefore: Int?
        var autoCreatePending: Bool; var note: String; var createdAt: Date }
    struct BudgetDTO: Codable { var id: UUID; var categoryID: UUID; var limit: Int64 }
    struct GoalDTO: Codable { var id: UUID; var title: String; var target: Int64; var saved: Int64; var monthly: Int64
        var targetDate: Date?; var accountID: UUID?; var createdAt: Date }
    struct TemplateDTO: Codable { var id: UUID; var title: String; var amount: Int64; var scope: String; var categoryID: UUID?
        var accountID: UUID?; var paymentMethod: String?; var useCount: Int }
    struct AliasDTO: Codable { var id: UUID; var walletLabel: String; var accountID: UUID }
    struct ClientDTO: Codable { var id: UUID; var name: String; var email: String; var phone: String; var taxId: String
        var bankName: String; var bankBranch: String; var bankAccount: String; var preferredPayment: String?
        var defaultCategoryID: UUID?; var defaultDescription: String; var lastAmount: Int64; var useCount: Int
        var lastUsedAt: Date; var note: String; var createdAt: Date }

    struct Payload: Codable {
        var accounts: [AccountDTO]; var categories: [CategoryDTO]; var entries: [EntryDTO]; var rules: [RuleDTO]
        var budgets: [BudgetDTO]; var goals: [GoalDTO]; var templates: [TemplateDTO]; var aliases: [AliasDTO]
        /// לקוחות שמורים (גיבויים ישנים — בלי השדה)
        var clients: [ClientDTO]? = nil
    }
    struct BackupFile: Codable {
        var format: String
        var version: Int
        var createdAt: Date
        var sha256: String
        var counts: [String: Int]
        var payload: Payload
    }

    enum BackupError: LocalizedError {
        case wrongFormat, newerVersion, checksumMismatch, invalidData(String)
        var errorDescription: String? {
            switch self {
            case .wrongFormat: return "הקובץ אינו גיבוי של האפליקציה."
            case .newerVersion: return "הגיבוי נוצר בגרסה חדשה יותר של האפליקציה."
            case .checksumMismatch: return "בדיקת התקינות נכשלה — הקובץ שונה או פגום. הנתונים הקיימים לא שונו."
            case .invalidData(let s): return "הגיבוי מכיל נתונים לא תקינים: \(s). הנתונים הקיימים לא שונו."
            }
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    static func checksum(_ payload: Payload) throws -> String {
        let data = try encoder().encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func makePayload() -> Payload {
        let l = Ledger(context: context)
        return Payload(
            accounts: l.accounts(includeArchived: true).map { AccountDTO(id: $0.id, name: $0.name, kind: $0.kindRaw, scope: $0.scopeRaw,
                knownBalance: $0.knownBalanceMinor, balanceDate: $0.balanceDate, billingDay: $0.billingDay,
                includeInTotals: $0.includeInTotals, isArchived: $0.isArchived, sortOrder: $0.sortOrder, createdAt: $0.createdAt) },
            categories: l.categories().map { CategoryDTO(id: $0.id, name: $0.name, scope: $0.scopeRaw, isIncome: $0.isIncome,
                isEssential: $0.isEssential, parentID: $0.parentID, symbol: $0.symbol, isArchived: $0.isArchived, sortOrder: $0.sortOrder,
                vatDeductibleBP: $0.vatDeductibleBP) },
            entries: l.entries().map { e in EntryDTO(id: e.id, kind: e.kindRaw, status: e.statusRaw, amount: e.amountMinor, date: e.date,
                title: e.title, scope: e.scopeRaw, categoryID: e.categoryID, subcategoryID: e.subcategoryID, accountID: e.accountID,
                toAccountID: e.toAccountID, paymentMethod: e.paymentMethodRaw, isFixed: e.isFixed, note: e.note,
                receiptImage: e.receiptImage, source: e.sourceRaw, certainty: e.certaintyRaw, cardLabel: e.cardLabel,
                externalRef: e.externalRef, rawAmountText: e.rawAmountText, possibleDuplicateOfID: e.possibleDuplicateOfID,
                recurringRuleID: e.recurringRuleID, occurrenceDate: e.occurrenceDate, splitGroupID: e.splitGroupID,
                refundOfID: e.refundOfID, importFingerprint: e.importFingerprint, createdAt: e.createdAt,
                updatedAt: e.updatedAt, confirmedAt: e.confirmedAt, vatMinor: e.vatMinor) },
            rules: l.recurring().map { r in RuleDTO(id: r.id, title: r.title, kind: r.kindRaw, amount: r.amountMinor,
                isVariableAmount: r.isVariableAmount, frequency: r.frequencyRaw, dayOfMonth: r.dayOfMonth, startDate: r.startDate,
                endDate: r.endDate, isPaused: r.isPaused, scope: r.scopeRaw, categoryID: r.categoryID, accountID: r.accountID,
                paymentMethod: r.paymentMethodRaw, remindDaysBefore: r.remindDaysBefore, autoCreatePending: r.autoCreatePending,
                note: r.note, createdAt: r.createdAt) },
            budgets: l.budgets().map { BudgetDTO(id: $0.id, categoryID: $0.categoryID, limit: $0.limitMinor) },
            goals: l.goals().map { GoalDTO(id: $0.id, title: $0.title, target: $0.targetMinor, saved: $0.savedMinor,
                monthly: $0.monthlyContributionMinor, targetDate: $0.targetDate, accountID: $0.accountID, createdAt: $0.createdAt) },
            templates: l.templates().map { TemplateDTO(id: $0.id, title: $0.title, amount: $0.amountMinor, scope: $0.scopeRaw,
                categoryID: $0.categoryID, accountID: $0.accountID, paymentMethod: $0.paymentMethodRaw, useCount: $0.useCount) },
            aliases: l.cardAliases().map { AliasDTO(id: $0.id, walletLabel: $0.walletLabel, accountID: $0.accountID) },
            clients: ((try? context.fetch(FetchDescriptor<Client>())) ?? []).map {
                ClientDTO(id: $0.id, name: $0.name, email: $0.email, phone: $0.phone, taxId: $0.taxId, bankName: $0.bankName,
                          bankBranch: $0.bankBranch, bankAccount: $0.bankAccount, preferredPayment: $0.preferredPaymentRaw,
                          defaultCategoryID: $0.defaultCategoryID, defaultDescription: $0.defaultDescription,
                          lastAmount: $0.lastAmountMinor, useCount: $0.useCount, lastUsedAt: $0.lastUsedAt, note: $0.note, createdAt: $0.createdAt)
            })
    }

    /// יוצר קובץ גיבוי בתיקייה הזמנית ומחזיר את הכתובת לשיתוף/שמירה
    func exportBackup(now: Date = .now) throws -> URL {
        let payload = makePayload()
        let file = BackupFile(format: "kesef-backup", version: Self.formatVersion, createdAt: now,
                              sha256: try Self.checksum(payload),
                              counts: ["accounts": payload.accounts.count, "entries": payload.entries.count,
                                       "rules": payload.rules.count, "categories": payload.categories.count],
                              payload: payload)
        let data = try Self.encoder().encode(file)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kesef-backup-\(f.string(from: now)).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// קורא ובודק גיבוי בלי לשנות דבר. מחזיר את הקובץ לתצוגה מקדימה.
    static func validate(data: Data) throws -> BackupFile {
        let file: BackupFile
        do { file = try decoder().decode(BackupFile.self, from: data) } catch { throw BackupError.wrongFormat }
        guard file.format == "kesef-backup" else { throw BackupError.wrongFormat }
        guard file.version <= formatVersion else { throw BackupError.newerVersion }
        guard try checksum(file.payload) == file.sha256 else { throw BackupError.checksumMismatch }
        let p = file.payload
        func unique<T>(_ items: [T], _ id: (T) -> UUID, _ name: String) throws {
            if Set(items.map(id)).count != items.count { throw BackupError.invalidData("מזהים כפולים ב\(name)") }
        }
        try unique(p.accounts, { $0.id }, "חשבונות")
        try unique(p.entries, { $0.id }, "תנועות")
        try unique(p.categories, { $0.id }, "קטגוריות")
        try unique(p.rules, { $0.id }, "חיובים קבועים")
        if p.entries.contains(where: { $0.amount < 0 }) { throw BackupError.invalidData("סכום שלילי בתנועה") }
        if p.entries.contains(where: { EntryKind(rawValue: $0.kind) == nil || EntryStatus(rawValue: $0.status) == nil }) {
            throw BackupError.invalidData("סוג או סטטוס לא מוכר")
        }
        if file.counts["entries"] != p.entries.count || file.counts["accounts"] != p.accounts.count {
            throw BackupError.invalidData("מספר הרשומות לא תואם")
        }
        return file
    }

    /// שחזור מלא: מחליף את כל הנתונים. נקרא רק אחרי validate ואישור מפורש של המשתמש.
    /// לפני השחזור נשמר עותק ביטחון של המצב הנוכחי בתיקיית המסמכים של האפליקציה (מוחזר למשתמש).
    @discardableResult
    func restore(_ file: BackupFile) throws -> URL {
        let safety = try exportBackup()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safetyURL = docs.appendingPathComponent("before-restore-" + safety.lastPathComponent)
        try? FileManager.default.removeItem(at: safetyURL)
        try FileManager.default.copyItem(at: safety, to: safetyURL)

        let l = Ledger(context: context)
        // שלב 1: מחיקה ושמירה (כדי שמזהים ייחודיים לא יתנגשו בהכנסה מחדש)
        l.entries().forEach { context.delete($0) }
        l.accounts(includeArchived: true).forEach { context.delete($0) }
        l.categories().forEach { context.delete($0) }
        l.recurring().forEach { context.delete($0) }
        l.budgets().forEach { context.delete($0) }
        l.goals().forEach { context.delete($0) }
        l.templates().forEach { context.delete($0) }
        l.cardAliases().forEach { context.delete($0) }
        if file.payload.clients != nil { ((try? context.fetch(FetchDescriptor<Client>())) ?? []).forEach { context.delete($0) } }
        try context.save()
        // שלב 2: הכנסת הנתונים מהגיבוי
        do {
            let p = file.payload
            for a in p.accounts {
                let m = Account(name: a.name, kind: AccountKind(rawValue: a.kind) ?? .other, scope: Scope(rawValue: a.scope) ?? .personal,
                                knownBalance: Money(minorUnits: a.knownBalance), balanceDate: a.balanceDate, billingDay: a.billingDay, sortOrder: a.sortOrder)
                m.id = a.id; m.includeInTotals = a.includeInTotals; m.isArchived = a.isArchived; m.createdAt = a.createdAt
                context.insert(m)
            }
            for c in p.categories {
                let m = Category(name: c.name, scope: Scope(rawValue: c.scope) ?? .personal, isIncome: c.isIncome, isEssential: c.isEssential,
                                 parentID: c.parentID, symbol: c.symbol, sortOrder: c.sortOrder)
                m.id = c.id; m.isArchived = c.isArchived; m.vatDeductibleBP = c.vatDeductibleBP ?? 10_000
                context.insert(m)
            }
            for e in p.entries {
                let m = Entry(kind: EntryKind(rawValue: e.kind) ?? .expense, status: EntryStatus(rawValue: e.status) ?? .confirmed,
                              amount: Money(minorUnits: e.amount), date: e.date, title: e.title, scope: Scope(rawValue: e.scope) ?? .personal,
                              categoryID: e.categoryID, accountID: e.accountID, source: EntrySource(rawValue: e.source) ?? .backup)
                m.id = e.id; m.subcategoryID = e.subcategoryID; m.toAccountID = e.toAccountID; m.paymentMethodRaw = e.paymentMethod
                m.isFixed = e.isFixed; m.note = e.note; m.receiptImage = e.receiptImage; m.certaintyRaw = e.certainty
                m.cardLabel = e.cardLabel; m.externalRef = e.externalRef; m.rawAmountText = e.rawAmountText
                m.possibleDuplicateOfID = e.possibleDuplicateOfID; m.recurringRuleID = e.recurringRuleID
                m.occurrenceDate = e.occurrenceDate; m.splitGroupID = e.splitGroupID; m.refundOfID = e.refundOfID
                m.importFingerprint = e.importFingerprint; m.createdAt = e.createdAt; m.updatedAt = e.updatedAt; m.confirmedAt = e.confirmedAt
                m.vatMinor = e.vatMinor
                context.insert(m)
            }
            for r in p.rules {
                let m = RecurringRule(title: r.title, kind: EntryKind(rawValue: r.kind) ?? .expense, amount: Money(minorUnits: r.amount),
                                      frequency: Frequency(rawValue: r.frequency) ?? .monthly, dayOfMonth: r.dayOfMonth,
                                      startDate: r.startDate, scope: Scope(rawValue: r.scope) ?? .personal)
                m.id = r.id; m.isVariableAmount = r.isVariableAmount; m.endDate = r.endDate; m.isPaused = r.isPaused
                m.categoryID = r.categoryID; m.accountID = r.accountID; m.paymentMethodRaw = r.paymentMethod
                m.remindDaysBefore = r.remindDaysBefore; m.autoCreatePending = r.autoCreatePending; m.note = r.note; m.createdAt = r.createdAt
                context.insert(m)
            }
            for b in p.budgets { let m = Budget(categoryID: b.categoryID, limit: Money(minorUnits: b.limit)); m.id = b.id; context.insert(m) }
            for g in p.goals {
                let m = SavingsGoal(title: g.title, target: Money(minorUnits: g.target), monthlyContribution: Money(minorUnits: g.monthly), targetDate: g.targetDate)
                m.id = g.id; m.savedMinor = g.saved; m.accountID = g.accountID; m.createdAt = g.createdAt
                context.insert(m)
            }
            for t in p.templates {
                let m = ExpenseTemplate(title: t.title, amount: Money(minorUnits: t.amount), scope: Scope(rawValue: t.scope) ?? .personal,
                                        categoryID: t.categoryID, accountID: t.accountID, paymentMethod: t.paymentMethod.flatMap(PaymentMethod.init(rawValue:)))
                m.id = t.id; m.useCount = t.useCount
                context.insert(m)
            }
            for a in p.aliases { let m = CardAlias(walletLabel: a.walletLabel, accountID: a.accountID); m.id = a.id; context.insert(m) }
            for c in p.clients ?? [] {
                let m = Client(name: c.name)
                m.id = c.id; m.email = c.email; m.phone = c.phone; m.taxId = c.taxId; m.bankName = c.bankName
                m.bankBranch = c.bankBranch; m.bankAccount = c.bankAccount; m.preferredPaymentRaw = c.preferredPayment
                m.defaultCategoryID = c.defaultCategoryID; m.defaultDescription = c.defaultDescription; m.lastAmountMinor = c.lastAmount
                m.useCount = c.useCount; m.lastUsedAt = c.lastUsedAt; m.note = c.note; m.createdAt = c.createdAt
                context.insert(m)
            }
            try context.save()
            return safetyURL
        } catch {
            context.rollback()
            throw BackupError.invalidData("השחזור נכשל (\(error.localizedDescription)). עותק ביטחון של הנתונים הקודמים נשמר: \(safetyURL.lastPathComponent)")
        }
    }

    /// מחיקת כל הנתונים (רק אחרי אישור כפול במסך ההגדרות). הקטגוריות חוזרות לברירת המחדל.
    func eraseAll() throws {
        let l = Ledger(context: context)
        l.entries().forEach { context.delete($0) }
        l.accounts(includeArchived: true).forEach { context.delete($0) }
        l.categories().forEach { context.delete($0) }
        l.recurring().forEach { context.delete($0) }
        l.budgets().forEach { context.delete($0) }
        l.goals().forEach { context.delete($0) }
        l.templates().forEach { context.delete($0) }
        l.cardAliases().forEach { context.delete($0) }
        try context.save()
        Seed.ensureDefaults(in: context)
    }
}
