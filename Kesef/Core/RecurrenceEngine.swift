import Foundation

public enum RecurrenceEngine {
    /// מועדי החיוב של כלל קבוע בטווח [from, to). כלל מושהה לא מייצר מועדים.
    public static func occurrences(of r: RecurringSnapshot, from: Date, to: Date, calendar cal: FinanceCalendar = .israel) -> [Date] {
        guard !r.isPaused, from < to else { return [] }
        let start = cal.startOfDay(r.startDate)
        var result: [Date] = []
        let endLimit = r.endDate.map { cal.startOfDay($0) }

        func accept(_ d: Date) -> Bool {
            d >= start && d >= cal.startOfDay(from) && d < to && (endLimit == nil || d <= endLimit!)
        }

        if let step = r.frequency.monthStep {
            var monthStart = cal.startOfMonth(start)
            // קפיצה קדימה כדי לא לרוץ מאות איטרציות על כללים ישנים
            let monthsGap = cal.calendar.dateComponents([.month], from: monthStart, to: cal.startOfMonth(from)).month ?? 0
            if monthsGap > step {
                let jumps = (monthsGap / step) - 1
                monthStart = cal.addMonths(jumps * step, to: monthStart)
            }
            var guardCount = 0
            while guardCount < 600 {
                guardCount += 1
                let d = cal.date(inMonthOf: monthStart, day: r.dayOfMonth)
                if d >= to { break }
                if let endLimit, d > endLimit { break }
                if accept(d) { result.append(d) }
                monthStart = cal.addMonths(step, to: monthStart)
            }
        } else {
            var d = start
            let daysGap = cal.daysBetween(start, from)
            if daysGap > 7 { d = cal.addDays((daysGap / 7 - 1) * 7, to: start) }
            var guardCount = 0
            while d < to && guardCount < 600 {
                guardCount += 1
                if let endLimit, d > endLimit { break }
                if accept(d) { result.append(d) }
                d = cal.addDays(7, to: d)
            }
        }
        return result
    }

    /// מועד הבא (כולל היום)
    public static func nextOccurrence(of r: RecurringSnapshot, onOrAfter d: Date, calendar cal: FinanceCalendar = .israel) -> Date? {
        occurrences(of: r, from: cal.startOfDay(d), to: cal.addMonths(13, to: d), calendar: cal).first
    }

    /// האם המועד הזה כבר נרשם כתנועה (בכל סטטוס, כולל בוטלה)
    public static func isRecorded(rule: UUID, occurrence: Date, entries: [EntrySnapshot], calendar cal: FinanceCalendar = .israel) -> Bool {
        entries.contains { e in
            e.recurringRuleID == rule && e.occurrenceDate.map { cal.isSameDay($0, occurrence) } == true
        }
    }
}
