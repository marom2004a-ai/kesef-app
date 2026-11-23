import Foundation
import SwiftData

/// פעולות על תנועות: תשלום חלקי, פריסת תשלומים מלקוח, זיכוי, מחיקה, רישום חיובים קבועים.
@MainActor
struct LedgerService {
    let context: ModelContext
    var cal = FinanceCalendar.israel

    enum LedgerError: LocalizedError {
        case invalidAmount, partialTooLarge
        var errorDescription: String? {
            switch self {
            case .invalidAmount: return "הסכום חייב להיות גדול מאפס."
            case .partialTooLarge: return "הסכום שהתקבל גדול מהסכום הצפוי. אשר את ההכנסה במלואה במקום."
            }
        }
    }

    /// הכנסה צפויה שהתקבלה חלקית: החלק שהתקבל מאושר, היתרה נשארת צפויה באותה קבוצה.
    func receivePartial(_ expected: Entry, received: Money, on date: Date) throws {
        guard received.isPositive else { throw LedgerError.invalidAmount }
        guard received < expected.amount else { throw LedgerError.partialTooLarge }
        let group = expected.splitGroupID ?? UUID()
        let remaining = expected.amount - received
        let done = Entry(kind: .income, status: .confirmed, amount: received, date: date, title: expected.title,
                         scope: expected.scope, categoryID: expected.categoryID, accountID: expected.accountID, source: expected.source)
        done.paymentMethod = expected.paymentMethod
        done.splitGroupID = group
        done.note = "תשלום חלקי"
        context.insert(done)
        expected.amount = remaining
        expected.splitGroupID = group
        expected.updatedAt = .now
        try context.save()
    }

    /// פריסת הכנסה מלקוח למספר תשלומים חודשיים צפויים (סכומם שווה בדיוק לסך הכול)
    @discardableResult
    func createInstallments(total: Money, count: Int, firstDate: Date, title: String, scope: Scope,
                            categoryID: UUID?, accountID: UUID?, certainty: Certainty, note: String) throws -> [Entry] {
        guard total.isPositive, count >= 1 else { throw LedgerError.invalidAmount }
        let group = UUID()
        var result: [Entry] = []
        for (i, part) in total.split(into: count).enumerated() {
            let e = Entry(kind: .income, status: .planned, amount: part, date: cal.addMonths(i, to: firstDate),
                          title: count > 1 ? "\(title) (\(i + 1)/\(count))" : title, scope: scope,
                          categoryID: categoryID, accountID: accountID)
            e.certainty = certainty
            e.splitGroupID = group
            e.note = note
            context.insert(e)
            result.append(e)
        }
        try context.save()
        return result
    }

    /// זיכוי על הוצאה קיימת (מפחית את ההוצאה בקטגוריה)
    @discardableResult
    func refund(_ original: Entry, amount: Money, date: Date) throws -> Entry {
        guard amount.isPositive else { throw LedgerError.invalidAmount }
        let r = Entry(kind: .refund, status: .confirmed, amount: amount, date: date, title: "זיכוי: \(original.title)",
                      scope: original.scope, categoryID: original.categoryID, accountID: original.accountID)
        r.refundOfID = original.id
        context.insert(r)
        try context.save()
        return r
    }

    func delete(_ entry: Entry) throws {
        context.delete(entry)
        try context.save()
    }

    func markReceived(_ entry: Entry, on date: Date = .now) throws {
        entry.status = .confirmed
        entry.date = date
        entry.confirmedAt = .now
        entry.updatedAt = .now
        try context.save()
    }

    /// רושם תנועה ממתינה לאישור עבור כל מועד חיוב קבוע שהגיע ולא נרשם (עד 60 יום אחורה).
    @discardableResult
    func postDueRecurring(now: Date = .now) throws -> Int {
        let ledger = Ledger(context: context)
        let snapshots = ledger.entries().map(\.snapshot)
        var created = 0
        for rule in ledger.recurring() where rule.autoCreatePending && !rule.isPaused {
            let from = Swift.max(cal.startOfDay(rule.createdAt), cal.addDays(-60, to: cal.startOfDay(now)))
            let to = cal.addDays(1, to: cal.startOfDay(now))
            for occ in RecurrenceEngine.occurrences(of: rule.snapshot, from: from, to: to, calendar: cal) {
                if RecurrenceEngine.isRecorded(rule: rule.id, occurrence: occ, entries: snapshots, calendar: cal) { continue }
                let e = Entry(kind: rule.kind == .income ? .income : .expense, status: .pendingReview, amount: rule.amount,
                              date: cal.calendar.date(byAdding: .hour, value: 9, to: occ) ?? occ, title: rule.title,
                              scope: rule.scope, categoryID: rule.categoryID, accountID: rule.accountID, source: .recurring)
                e.recurringRuleID = rule.id
                e.occurrenceDate = occ
                e.isFixed = true
                e.paymentMethod = rule.paymentMethod
                if rule.isVariableAmount { e.note = "סכום משוער — עדכן לפי החיוב בפועל" }
                context.insert(e)
                created += 1
            }
        }
        if created > 0 { try context.save() }
        return created
    }

    /// עדכון יתרה מול הבנק: היתרה החדשה נכונה לרגע זה, ותנועות קודמות כבר כלולות בה.
    func reconcile(_ account: Account, actualBalance: Money, at date: Date = .now) throws {
        account.knownBalance = actualBalance
        account.balanceDate = date
        try context.save()
    }
}
