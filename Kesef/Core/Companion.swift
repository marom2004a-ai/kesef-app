import Foundation

// MARK: - רווח לפי חודשים

public struct MonthPoint: Hashable, Sendable {
    public var monthStart: Date
    public var value: Money
}

public enum MonthlySeries {
    /// רווח העסק אחרי מע״מ לכל חודש (מהישן לחדש), כולל החודש הנוכחי
    public static func businessProfit(entries: [EntrySnapshot], months: Int, now: Date, vat: VatSettings,
                                      deductibleBP: [UUID: Int] = [:], calendar cal: FinanceCalendar = .israel) -> [MonthPoint] {
        (0..<max(1, months)).reversed().map { back in
            let start = cal.addMonths(-back, to: cal.startOfMonth(now))
            let range = start..<cal.addMonths(1, to: start)
            let st = VatEngine.statement(entries: entries, period: range, settings: vat, deductibleBP: deductibleBP, calendar: cal)
            return MonthPoint(monthStart: start, value: st.profitBeforeTax)
        }
    }

    /// נטו אישי (הכנסות פחות הוצאות) לכל חודש
    public static func personalNet(entries: [EntrySnapshot], months: Int, now: Date, calendar cal: FinanceCalendar = .israel) -> [MonthPoint] {
        (0..<max(1, months)).reversed().map { back in
            let start = cal.addMonths(-back, to: cal.startOfMonth(now))
            let range = start..<cal.addMonths(1, to: start)
            return MonthPoint(monthStart: start, value: BalanceEngine.summary(entries: entries, in: range, scope: .personal).net)
        }
    }

    /// שינוי באחוזים (נקודות בסיס) מול הערך הקודם. nil כשאין בסיס להשוואה (קודם אפס או שלילי)
    public static func changeBP(current: Money, previous: Money) -> Int? {
        guard previous.isPositive else { return nil }
        return Money.ratioBasisPoints(current - previous, of: previous)
    }

    /// האם החודש האחרון הוא שיא (גבוה מכל החודשים הקודמים בסדרה, וחיובי)
    public static func isRecord(_ series: [MonthPoint]) -> Bool {
        guard let last = series.last, last.value.isPositive, series.count > 1 else { return false }
        return series.dropLast().allSatisfy { $0.value < last.value }
    }
}

// MARK: - סדרות

public enum Streaks {
    /// כמה הוצאות עסקיות ברצף (מהחדשה לישנה) צולמו להן קבלות
    public static func receipts(hasReceiptNewestFirst: [Bool]) -> Int {
        hasReceiptNewestFirst.prefix { $0 }.count
    }
}

// MARK: - הכלב המלווה

public enum CompanionMood: String, Sendable {
    case happy, proud, alert, calm
}

public struct CompanionMessage: Hashable, Sendable {
    public var mood: CompanionMood
    public var text: String
}

public struct CompanionInput: Sendable {
    public var isBusiness: Bool
    public var pendingCount: Int = 0
    public var missingReceipts: Int = 0
    /// הכנסות עסקיות שעוד לא הופקה להן קבלה
    public var incomesAwaitingReceipt: Int = 0
    /// הגיע יום ההעברה החודשית ונשאר להעביר לעצמי
    public var drawDue: Money = .zero
    public var receiptStreak: Int = 0
    /// שינוי ברווח (עסקי) או בנטו (אישי) מול החודש הקודם, בנקודות בסיס
    public var changeBP: Int?
    public var isRecordMonth: Bool = false
    public var savedThisMonth: Money = .zero
    public var savingsTarget: Money = .zero
    public var dayOfMonth: Int = 15

    public init(isBusiness: Bool, pendingCount: Int = 0, missingReceipts: Int = 0, receiptStreak: Int = 0, changeBP: Int? = nil,
                isRecordMonth: Bool = false, savedThisMonth: Money = .zero, savingsTarget: Money = .zero, dayOfMonth: Int = 15,
                incomesAwaitingReceipt: Int = 0, drawDue: Money = .zero) {
        self.drawDue = drawDue
        self.isBusiness = isBusiness; self.pendingCount = pendingCount; self.missingReceipts = missingReceipts
        self.incomesAwaitingReceipt = incomesAwaitingReceipt
        self.receiptStreak = receiptStreak; self.changeBP = changeBP; self.isRecordMonth = isRecordMonth
        self.savedThisMonth = savedThisMonth; self.savingsTarget = savingsTarget; self.dayOfMonth = dayOfMonth
    }
}

/// משפט אחד קצר מהכלב, לפי מה שהכי חשוב עכשיו. כללים קבועים — בלי ניחושים.
public enum CompanionAdvisor {
    public static func message(_ i: CompanionInput) -> CompanionMessage {
        if i.pendingCount > 0 {
            return .init(mood: .alert, text: i.pendingCount == 1
                ? "יש רכישה אחת שמחכה לאישור שלך. שתי שניות וסיימנו!"
                : "יש \(i.pendingCount) רכישות שמחכות לאישור. בוא נסדר אותן!")
        }
        if !i.isBusiness && i.drawDue.isPositive {
            return .init(mood: .happy, text: "הגיע הזמן להעביר לעצמך מהעסק — מגיע לך \(MoneyFormat.string(i.drawDue)). לחץ על ״הכנסה״ 💸")
        }
        if i.isBusiness && i.incomesAwaitingReceipt > 0 {
            return .init(mood: .alert, text: i.incomesAwaitingReceipt == 1
                ? "יש הכנסה אחת שעוד לא הופקה לה קבלה. נפיק?"
                : "יש \(i.incomesAwaitingReceipt) הכנסות שמחכות לקבלה. נפיק?")
        }
        if i.isBusiness && i.missingReceipts > 0 {
            return .init(mood: .alert, text: i.missingReceipts == 1
                ? "חסרה קבלה אחת בתקופה הזו. צלם אותה ואתה מסודר!"
                : "חסרות \(i.missingReceipts) קבלות בתקופה הזו. נצלם?")
        }
        if i.isRecordMonth {
            return .init(mood: .proud, text: i.isBusiness ? "חודש שיא לעסק! אתם תותחים 🏆" : "החודש הכי טוב שלך עד עכשיו! 🏆")
        }
        if let c = i.changeBP, c >= 1000 {
            return .init(mood: .happy, text: "עלייה של \(c / 100)% מהחודש שעבר. ממשיכים ככה!")
        }
        if !i.isBusiness && i.savingsTarget.isPositive {
            if i.savedThisMonth >= i.savingsTarget { return .init(mood: .proud, text: "עמדת ביעד החיסכון של החודש! 🎉") }
            if i.savedThisMonth.isPositive {
                let pct = Money.ratioBasisPoints(i.savedThisMonth, of: i.savingsTarget).map { $0 / 100 } ?? 0
                return .init(mood: .happy, text: "כבר \(pct)% מיעד החיסכון. עוד קצת!")
            }
        }
        if let c = i.changeBP, c <= -1500, i.dayOfMonth >= 20 {
            return .init(mood: .calm, text: "החודש קצת חלש מהקודם. נבדוק יחד איפה אפשר לשפר?")
        }
        if i.isBusiness && i.receiptStreak >= 5 {
            return .init(mood: .proud, text: "\(i.receiptStreak) קבלות ברצף! רואה החשבון יאהב אותך.")
        }
        return .init(mood: .calm, text: i.isBusiness ? "הכול מסודר. אני פה אם צריך משהו 🐾" : "הכול רגוע. תלחץ עליי לייעוץ 🐾")
    }
}

// MARK: - העברה חודשית לעצמי ("הכנסה מהעסק")

public struct DrawSuggestion: Hashable, Sendable {
    /// החודש שעל הרווח שלו מחושב החלק
    public var profitMonth: Date
    /// החלק שלי מרווח החודש הקודם (אחרי מע״מ ואחרי חלק השותף)
    public var myShare: Money
    /// כמה כבר הועבר אליי החודש
    public var drawnThisMonth: Money
    /// מה שנשאר להעביר (לא שלילי)
    public var remaining: Money { let r = myShare - drawnThisMonth; return r.isPositive ? r : .zero }
}

public enum OwnerDrawPlanner {
    public static func suggestion(entries: [EntrySnapshot], now: Date, vat: VatSettings, deductibleBP: [UUID: Int] = [:],
                                  partnerShareBP: Int, calendar cal: FinanceCalendar = .israel) -> DrawSuggestion {
        let thisMonth = cal.startOfMonth(now)
        let prev = cal.addMonths(-1, to: thisMonth)
        let st = VatEngine.statement(entries: entries, period: prev..<thisMonth, settings: vat, deductibleBP: deductibleBP, calendar: cal)
        let mine = max(0, min(10_000, 10_000 - partnerShareBP))
        let share = st.profitBeforeTax.isPositive ? st.profitBeforeTax.multiplied(byBasisPoints: mine) : .zero
        let month = cal.monthRange(now)
        let drawn = entries.filter { $0.kind == .ownerDraw && $0.status == .confirmed && month.contains($0.date) }.map(\.amount).sum()
        return DrawSuggestion(profitMonth: prev, myShare: share, drawnThisMonth: drawn)
    }

    /// מועד התזכורת הבא: יום drawDay בשעה 9:00 — החודש אם עוד לא עבר, אחרת בחודש הבא
    public static func nextReminder(after now: Date, drawDay: Int, calendar cal: FinanceCalendar = .israel) -> Date {
        func at(_ monthStart: Date) -> Date {
            let day = cal.date(inMonthOf: monthStart, day: drawDay)
            return cal.calendar.date(byAdding: .hour, value: 9, to: cal.startOfDay(day)) ?? day
        }
        let thisMonth = at(cal.startOfMonth(now))
        return thisMonth > now ? thisMonth : at(cal.addMonths(1, to: cal.startOfMonth(now)))
    }
}
