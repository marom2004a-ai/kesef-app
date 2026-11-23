import Foundation

/// לוח שנה גרגוריאני באזור הזמן של ישראל — כל חישובי החודשים עוברים דרכו.
public struct FinanceCalendar: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar) { self.calendar = calendar }

    public static var israel: FinanceCalendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        c.locale = Locale(identifier: "he_IL")
        c.firstWeekday = 1
        return FinanceCalendar(calendar: c)
    }

    public func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }

    public func startOfMonth(_ d: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: d)
        return calendar.date(from: comps) ?? startOfDay(d)
    }

    /// תחילת החודש הבא (גבול עליון לא כולל)
    public func endOfMonth(_ d: Date) -> Date { addMonths(1, to: startOfMonth(d)) }

    public func monthRange(_ d: Date) -> Range<Date> { startOfMonth(d)..<endOfMonth(d) }

    public func addDays(_ n: Int, to d: Date) -> Date { calendar.date(byAdding: .day, value: n, to: d) ?? d }
    public func addMonths(_ n: Int, to d: Date) -> Date { calendar.date(byAdding: .month, value: n, to: d) ?? d }

    public func daysInMonth(_ d: Date) -> Int { calendar.range(of: .day, in: .month, for: d)?.count ?? 30 }

    public func day(_ d: Date) -> Int { calendar.component(.day, from: d) }

    public func isSameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }

    /// תאריך עם יום מוגבל לאורך החודש (31 בפברואר → 28/29)
    public func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents(year: year, month: month, day: 1)
        let first = calendar.date(from: comps) ?? Date()
        let maxDay = daysInMonth(first)
        comps.day = Swift.max(1, Swift.min(day, maxDay))
        return calendar.date(from: comps) ?? first
    }

    /// יום ב-monthStart (תחילת חודש) מוגבל לאורך החודש
    public func date(inMonthOf monthStart: Date, day: Int) -> Date {
        let c = calendar.dateComponents([.year, .month], from: monthStart)
        return date(year: c.year ?? 2000, month: c.month ?? 1, day: day)
    }

    public func daysBetween(_ a: Date, _ b: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(a), to: startOfDay(b)).day ?? 0
    }

    public func monthKey(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month], from: d)
        let m = c.month ?? 1
        return "\(c.year ?? 0)-\(m < 10 ? "0" : "")\(m)"
    }

    /// N חודשים שלמים אחרונים לפני החודש של `d` (מהישן לחדש)
    public func completeMonths(before d: Date, count: Int) -> [Date] {
        let current = startOfMonth(d)
        return (1...Swift.max(1, count)).reversed().map { addMonths(-$0, to: current) }
    }

    /// תאריך החיוב הבא (כולל היום) ביום billingDay בחודש
    public func nextBillingDate(onOrAfter d: Date, billingDay: Int) -> Date {
        let day0 = startOfDay(d)
        let thisMonth = date(inMonthOf: startOfMonth(day0), day: billingDay)
        if thisMonth >= day0 { return thisMonth }
        return date(inMonthOf: addMonths(1, to: startOfMonth(day0)), day: billingDay)
    }
}
