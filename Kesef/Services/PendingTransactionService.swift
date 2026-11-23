import Foundation
import SwiftData

/// קליטה, אישור, פיצול ודחייה של רכישות שמגיעות מאוטומציית Wallet.
/// רכישה נכנסת נשמרת תמיד בסטטוס "ממתינה לאישור" — לעולם לא כמאושרת.
@MainActor
struct PendingTransactionService {
    let context: ModelContext
    var now: () -> Date = { .now }

    enum IngestResult: Equatable {
        case created(UUID, needsDetails: Bool, possibleDuplicate: Bool)
        case duplicateIgnored(UUID)
    }

    /// נקרא מה-App Intent. amountText מגיע כטקסט מ-Shortcuts (למשל "₪45.90").
    /// markAutomationRun=false לבדיקה מתוך האפליקציה — כדי לא להציג את האוטומציה כפעילה לפני שרצה באמת מ-Shortcuts.
    func ingestApplePay(amountText: String?, merchant: String?, cardLabel: String?, details: String? = nil,
                        externalID: String? = nil, markAutomationRun: Bool = true) throws -> IngestResult {
        let ledger = Ledger(context: context)
        let fromText = details.map(WalletTextParser.parse)
        let parsed = amountText.flatMap(AmountParser.parse)?.absolute
        let amount = (parsed?.isPositive == true) ? parsed : fromText?.amount
        func nonEmpty(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines); return (t?.isEmpty == false) ? t : nil
        }
        let cleanMerchant = nonEmpty(merchant) ?? fromText?.merchant
        let cleanCard = nonEmpty(cardLabel) ?? fromText?.card
        let received = now()

        let incoming = IncomingPurchase(amount: amount, merchant: cleanMerchant, cardLabel: cleanCard,
                                        externalID: externalID, receivedAt: received)
        let since = received.addingTimeInterval(-DuplicateDetector.similarWindow - 60)
        let candidates = ledger.entries()
            .filter { $0.source == .applePayShortcut && $0.createdAt >= since }
            .map { PurchaseCandidate(id: $0.id, amount: $0.amountMinor == 0 ? nil : $0.amount,
                                     merchant: $0.cardOrigMerchant, cardLabel: $0.cardLabel,
                                     externalID: $0.externalRef, receivedAt: $0.createdAt) }

        let verdict = DuplicateDetector.check(incoming, against: candidates)
        if case .rerun(let id) = verdict { return .duplicateIgnored(id) }

        let scope = AppSettings.defaultApplePayScope
        let entry = Entry(kind: .expense, status: .pendingReview, amount: amount ?? .zero, date: received,
                          title: cleanMerchant ?? "", scope: scope, source: .applePayShortcut)
        entry.createdAt = received
        entry.updatedAt = received
        entry.paymentMethod = .applePay
        entry.cardLabel = (cleanCard?.isEmpty == false) ? cleanCard : nil
        entry.externalRef = externalID
        entry.rawAmountText = amountText
        if let d = nonEmpty(details) { entry.note = "טקסט מ-Wallet: " + d }
        entry.accountID = accountFor(cardLabel: cleanCard)
        if case .similar(let other) = verdict { entry.possibleDuplicateOfID = other }
        context.insert(entry)
        try context.save()

        // נשמר כמספר (שניות מ-2001) כדי ש-@AppStorage יוכל לקרוא אותו
        if markAutomationRun {
            UserDefaults.standard.set(received.timeIntervalSinceReferenceDate, forKey: AppSettings.Key.lastApplePayIntentAt)
        }
        return .created(entry.id, needsDetails: !incoming.isComplete, possibleDuplicate: entry.possibleDuplicateOfID != nil)
    }

    /// שיוך כרטיס: לפי כינוי ששמור, אחרת חשבון ברירת המחדל שנבחר בהגדרות
    func accountFor(cardLabel: String?) -> UUID? {
        let ledger = Ledger(context: context)
        if let label = cardLabel, !label.isEmpty {
            let key = DuplicateDetector.normalize(label)
            if let alias = ledger.cardAliases().first(where: { DuplicateDetector.normalize($0.walletLabel) == key }) {
                return alias.accountID
            }
        }
        return AppSettings.defaultApplePayAccountID
    }

    struct ConfirmRequest {
        var amount: Money
        var title: String
        var scope: Scope
        var categoryID: UUID?
        var accountID: UUID?
        var note: String
        /// פיצול: הסכום שהולך לחלק העסקי (השאר אישי). nil = ללא פיצול
        var businessSplitAmount: Money?
        var businessCategoryID: UUID?
        var personalCategoryID: UUID?
        var rememberCardForAccount: Bool = false
    }

    enum ConfirmError: LocalizedError {
        case invalidAmount, invalidSplit, missingTitle
        var errorDescription: String? {
            switch self {
            case .invalidAmount: return "הסכום חייב להיות גדול מאפס."
            case .invalidSplit: return "סכום הפיצול חייב להיות בין 0 לסכום המלא."
            case .missingTitle: return "חסר שם בית עסק או תיאור."
            }
        }
    }

    /// אישור ושמירה. עם פיצול — נוצרות שתי הוצאות מאושרות שסכומן שווה בדיוק לסכום המקורי.
    @discardableResult
    func confirm(_ entry: Entry, with r: ConfirmRequest) throws -> [Entry] {
        guard r.amount.isPositive else { throw ConfirmError.invalidAmount }
        let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ConfirmError.missingTitle }

        entry.title = title
        entry.note = r.note
        entry.accountID = r.accountID
        entry.updatedAt = now()
        entry.confirmedAt = now()
        entry.possibleDuplicateOfID = nil

        if r.rememberCardForAccount, let label = entry.cardLabel, let acc = r.accountID {
            let ledger = Ledger(context: context)
            if let existing = ledger.cardAliases().first(where: { DuplicateDetector.normalize($0.walletLabel) == DuplicateDetector.normalize(label) }) {
                existing.accountID = acc
            } else {
                context.insert(CardAlias(walletLabel: label, accountID: acc))
            }
        }

        if let business = r.businessSplitAmount, !business.isZero {
            guard business.isPositive, business < r.amount else { throw ConfirmError.invalidSplit }
            let personal = r.amount - business
            let group = UUID()
            entry.amount = personal
            entry.scope = .personal
            entry.categoryID = r.personalCategoryID
            entry.status = .confirmed
            entry.splitGroupID = group

            let b = Entry(kind: .expense, status: .confirmed, amount: business, date: entry.date, title: title,
                          scope: .business, categoryID: r.businessCategoryID, accountID: r.accountID, source: entry.source)
            b.paymentMethod = entry.paymentMethod
            b.cardLabel = entry.cardLabel
            b.splitGroupID = group
            b.note = r.note
            context.insert(b)
            try context.save()
            return [entry, b]
        }

        entry.amount = r.amount
        entry.scope = r.scope
        entry.categoryID = r.categoryID
        entry.status = .confirmed
        try context.save()
        return [entry]
    }

    /// אישור מהיר מההתראה: כמו שהגיע, בסיווג ברירת המחדל (אישי). רק אם יש סכום ושם.
    func quickConfirm(_ entry: Entry) throws -> Bool {
        guard entry.amount.isPositive, !entry.title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        entry.status = .confirmed
        entry.confirmedAt = now()
        entry.updatedAt = now()
        try context.save()
        return true
    }

    /// דחייה: נשמרת כמבוטלת (כדי שהפעלה חוזרת של האוטומציה לא תיצור אותה שוב)
    func reject(_ entry: Entry) throws {
        entry.status = .cancelled
        entry.updatedAt = now()
        try context.save()
    }

    func markNotDuplicate(_ entry: Entry) throws {
        entry.possibleDuplicateOfID = nil
        try context.save()
    }
}

extension Entry {
    /// שם בית העסק כפי שנקלט (להשוואת כפילויות)
    var cardOrigMerchant: String? { title.isEmpty ? nil : title }
}
