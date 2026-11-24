import Foundation
import UserNotifications
import SwiftData

/// התראות מקומיות בלבד (UNUserNotificationCenter). אין שרת ואין Push.
@MainActor
enum NotificationService {
    static let pendingCategory = "PENDING_PURCHASE"
    static let confirmPersonalAction = "CONFIRM_PERSONAL"
    static let reviewAction = "REVIEW"
    static let entryIDKey = "entryID"

    static var center: UNUserNotificationCenter { .current() }

    /// פעולות מהירות: "QUICK_food" / "QUICK_shopping" / "QUICK_other" — אישור כהוצאה אישית בקטגוריה; "עסקי" פותח את האפליקציה
    static let quickPrefix = "QUICK_"
    static let businessAction = "BUSINESS"

    static func registerCategories() {
        var actions: [UNNotificationAction] = PendingTransactionService.QuickChoice.allCases.map {
            UNNotificationAction(identifier: quickPrefix + $0.rawValue, title: "\($0.emoji) \($0.title)", options: [.authenticationRequired])
        }
        actions.append(UNNotificationAction(identifier: businessAction, title: "💼 עסקי (עם קבלה)", options: [.foreground]))
        let cat = UNNotificationCategory(identifier: pendingCategory, actions: actions, intentIdentifiers: [], options: [])
        center.setNotificationCategories([cat])
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// התראה על רכישה חדשה שממתינה לאישור. אם המשתמש לא אישר התראות — פשוט לא תוצג; העסקה עדיין בתיבת הממתינות.
    static func notifyPendingPurchase(entryID: UUID, merchant: String, amount: Money?, needsDetails: Bool, possibleDuplicate: Bool) async {
        let content = UNMutableNotificationContent()
        // הסכום בכותרת — הדבר הראשון שרואים. החזקה על ההתראה פותחת: אוכל / קניות / אחר / עסקי
        // רק הסכום — בלי שם בית עסק ובלי פרטים. החזקה על ההתראה: אוכל / קניות / אחר / עסקי
        content.title = amount.map { MoneyFormat.string($0) } ?? "רכישה חדשה"
        content.body = needsDetails ? "לחץ להשלמה" : "מה זה?"
        content.sound = .default
        content.userInfo = [entryIDKey: entryID.uuidString]
        if !needsDetails { content.categoryIdentifier = pendingCategory }
        let req = UNNotificationRequest(identifier: "pending-\(entryID.uuidString)", content: content, trigger: nil)
        try? await center.add(req)
    }

    /// תשלום נכנס מלקוח — לחיצה פותחת אישור והפקת קבלה
    static func notifyIncomingPayment(entryID: UUID, payer: String, amount: Money?) async {
        let content = UNMutableNotificationContent()
        content.title = "התקבל תשלום 💰"
        let a = amount.map { MoneyFormat.string($0) } ?? "סכום לא זוהה"
        content.body = "\(payer.isEmpty ? "תשלום נכנס" : payer) · \(a). לחץ לאישור והפקת קבלה."
        content.sound = .default
        content.userInfo = [entryIDKey: entryID.uuidString]
        try? await center.add(UNNotificationRequest(identifier: "pending-\(entryID.uuidString)", content: content, trigger: nil))
    }

    static func updateBadge(context: ModelContext) async {
        let count = Ledger(context: context).pendingCount()
        try? await center.setBadgeCount(count)
    }

    static func removePendingNotification(entryID: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: ["pending-\(entryID.uuidString)"])
    }

    /// תזמון תזכורות לחיובים קבועים ב-45 הימים הקרובים (iOS מגביל ל-64 התראות מתוזמנות)
    static func rescheduleBillReminders(context: ModelContext, now: Date = .now) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("bill-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard AppSettings.billRemindersEnabled else { return }
        let cal = FinanceCalendar.israel
        let ledger = Ledger(context: context)
        let entries = ledger.entries().map(\.snapshot)
        var requests: [(Date, UNNotificationRequest)] = []
        for rule in ledger.recurring() where !rule.isPaused && rule.kind == .expense {
            guard let days = rule.remindDaysBefore else { continue }
            let occ = RecurrenceEngine.occurrences(of: rule.snapshot, from: now, to: cal.addDays(45, to: now), calendar: cal)
            for o in occ where !RecurrenceEngine.isRecorded(rule: rule.id, occurrence: o, entries: entries, calendar: cal) {
                let fire = cal.calendar.date(byAdding: .hour, value: 9, to: cal.addDays(-days, to: o)) ?? o
                guard fire > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = days == 0 ? "חיוב היום" : "חיוב קרוב"
                let when = days == 0 ? "היום" : (days == 1 ? "מחר" : "בעוד \(days) ימים")
                content.body = "\(rule.title): \(MoneyFormat.string(rule.amount))\(rule.isVariableAmount ? " (משוער)" : "") — \(when)."
                content.sound = .default
                let comps = cal.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let id = "bill-\(rule.id.uuidString)-\(cal.monthKey(o))-\(cal.day(o))"
                requests.append((fire, UNNotificationRequest(identifier: id, content: content, trigger: trigger)))
            }
        }
        requests.sort { $0.0 < $1.0 }
        for (_, r) in requests.prefix(50) {
            try? await center.add(r)
        }
    }

    static let drawActionKey = "action"

    /// תזכורת חודשית להעברה לעצמי ("הכנסה מהעסק") ביום שנקבע, עם הסכום המוצע
    static func scheduleDrawReminder(context: ModelContext, now: Date = .now) async {
        center.removePendingNotificationRequests(withIdentifiers: ["draw-reminder"])
        let d = UserDefaults.standard
        guard d.bool(forKey: AppSettings.Key.drawReminderEnabled) else { return }
        let cal = FinanceCalendar.israel
        let ledger = Ledger(context: context)
        let fire = OwnerDrawPlanner.nextReminder(after: now, drawDay: max(1, min(28, d.integer(forKey: AppSettings.Key.drawDay))), calendar: cal)
        // ההצעה מחושבת לפי מועד התזכורת (רווח החודש שלפניו)
        let s = OwnerDrawPlanner.suggestion(entries: ledger.entries().map(\.snapshot), now: fire, vat: AppSettings.vat,
                                            deductibleBP: Dictionary(uniqueKeysWithValues: ledger.categories().map { ($0.id, $0.vatDeductibleBP) }),
                                            partnerShareBP: AppSettings.partner.shareBasisPoints, calendar: cal)
        let content = UNMutableNotificationContent()
        content.title = "היום מעבירים לעצמך 💸"
        content.body = s.myShare.isPositive
            ? "החלק שלך מהרווח של \(Fmt.monthYear(s.profitMonth)): \(MoneyFormat.string(s.myShare)). לחץ לרישום."
            : "הגיע היום להעברה החודשית מהעסק. לחץ לרישום."
        content.sound = .default
        content.userInfo = [drawActionKey: "draw"]
        let comps = cal.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        try? await center.add(UNNotificationRequest(identifier: "draw-reminder", content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// התראת תקציב — פעם אחת לכל רמה בחודש
    static func checkBudgets(context: ModelContext, now: Date = .now) async {
        guard AppSettings.budgetAlertsEnabled else { return }
        let cal = FinanceCalendar.israel
        let ledger = Ledger(context: context)
        let budgets = ledger.budgets()
        let names = Dictionary(uniqueKeysWithValues: ledger.categories().map { ($0.id, $0.name) })
        let statuses = BudgetEngine.status(budgets: budgets.map(\.snapshot), entries: ledger.entries().map(\.snapshot),
                                           month: now, now: now, alertBasisPoints: AppSettings.budgetAlertBasisPoints, calendar: cal)
        let monthKey = cal.monthKey(now)
        for st in statuses where st.level == .warning || st.level == .over {
            guard let b = budgets.first(where: { $0.id == st.budgetID }) else { continue }
            let already = b.lastAlertMonthKey == monthKey ? b.lastAlertLevel : 0
            guard st.level.rawValue > already else { continue }
            b.lastAlertMonthKey = monthKey
            b.lastAlertLevel = st.level.rawValue
            let content = UNMutableNotificationContent()
            let name = names[st.categoryID] ?? "קטגוריה"
            content.title = st.level == .over ? "חריגה מהתקציב" : "מתקרבים לתקרת התקציב"
            content.body = "\(name): נוצלו \(MoneyFormat.string(st.used)) מתוך \(MoneyFormat.string(st.limit)) (\(st.usedBasisPoints / 100)%)."
            try? await center.add(UNNotificationRequest(identifier: "budget-\(b.id.uuidString)-\(monthKey)-\(st.level.rawValue)", content: content, trigger: nil))
        }
        try? context.save()
    }
}
