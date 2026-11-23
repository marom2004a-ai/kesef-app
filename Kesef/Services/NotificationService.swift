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

    static func registerCategories() {
        let confirm = UNNotificationAction(identifier: confirmPersonalAction, title: "אשר כהוצאה אישית", options: [.authenticationRequired])
        let review = UNNotificationAction(identifier: reviewAction, title: "פתח לבדיקה", options: [.foreground])
        let cat = UNNotificationCategory(identifier: pendingCategory, actions: [confirm, review], intentIdentifiers: [], options: [])
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
        content.title = "זוהתה רכישה חדשה"
        let amountText = amount.map { MoneyFormat.string($0) } ?? "סכום חסר"
        let name = merchant.isEmpty ? "בית עסק לא ידוע" : merchant
        var body = "\(name) · \(amountText) · סווגה כ\(AppSettings.defaultApplePayScope.expenseLabel)."
        if needsDetails { body += " חסרים פרטים — יש להשלים." }
        if possibleDuplicate { body += " ייתכן שזו כפילות." }
        content.body = body
        content.sound = .default
        content.userInfo = [entryIDKey: entryID.uuidString]
        if !needsDetails { content.categoryIdentifier = pendingCategory }
        let req = UNNotificationRequest(identifier: "pending-\(entryID.uuidString)", content: content, trigger: nil)
        try? await center.add(req)
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
