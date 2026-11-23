import Foundation
#if canImport(FinanceCore)
@testable import FinanceCore
#else
@testable import Kesef
#endif

// כל הסכומים בבדיקות הם נתונים מומצאים לבדיקה בלבד.

let cal = FinanceCalendar.israel

func D(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    var c = DateComponents(year: y, month: m, day: d, hour: h, minute: min)
    c.timeZone = cal.calendar.timeZone
    return cal.calendar.date(from: c)!
}

func ILS(_ shekels: Int64, _ agorot: Int64 = 0) -> Money { Money(shekels: shekels, agorot: agorot) }

func expense(_ amount: Money, _ date: Date, account: UUID? = nil, category: UUID? = nil, scope: Scope = .personal,
             status: EntryStatus = .confirmed, fixed: Bool = false, rule: UUID? = nil, occurrence: Date? = nil) -> EntrySnapshot {
    EntrySnapshot(kind: .expense, status: status, amount: amount, date: date, title: "בדיקה", scope: scope,
                  categoryID: category, accountID: account, recurringRuleID: rule, occurrenceDate: occurrence, isFixed: fixed)
}

func income(_ amount: Money, _ date: Date, account: UUID? = nil, scope: Scope = .business,
            status: EntryStatus = .confirmed, certainty: Certainty = .high) -> EntrySnapshot {
    EntrySnapshot(kind: .income, status: status, amount: amount, date: date, title: "לקוח בדיקה", scope: scope,
                  accountID: account, certainty: certainty)
}
