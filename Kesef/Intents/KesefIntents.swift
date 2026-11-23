import AppIntents
import Foundation
import SwiftData

/// הפעולה שאוטומציית Wallet ב-Shortcuts מריצה אחרי תשלום Apple Pay.
/// מקבלת את מה ש-iOS מעביר (סכום, בית עסק, כרטיס — כל אחד יכול להיות חסר) ויוצרת עסקה ממתינה לאישור.
struct LogApplePayPurchaseIntent: AppIntent {
    static var title: LocalizedStringResource = "רישום רכישת Apple Pay"
    static var description = IntentDescription("יוצר הוצאה שממתינה לאישור באפליקציה. ההוצאה לא נשמרת כמאושרת עד שתאשר אותה.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "סכום", description: "Amount מתוך קלט הקיצור (טקסט כמו ₪45.90)")
    var amount: String?

    @Parameter(title: "בית עסק", description: "Merchant מתוך קלט הקיצור")
    var merchant: String?

    @Parameter(title: "כרטיס", description: "Card / Name מתוך קלט הקיצור")
    var card: String?

    /// כל קלט הקיצור כטקסט אחד — כשאי אפשר לבחור את השדות בנפרד (iOS 26). האפליקציה מחלצת ממנו סכום/בית עסק/כרטיס.
    @Parameter(title: "פרטי עסקה", description: "קלט הקיצור כולו (Shortcut Input)")
    var details: String?

    static var parameterSummary: some ParameterSummary {
        Summary("רשום רכישה מ-\(\.$details)") {
            \.$amount
            \.$merchant
            \.$card
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = Persistence.shared.mainContext
        let service = PendingTransactionService(context: context)
        let result = try service.ingestApplePay(amountText: amount, merchant: merchant, cardLabel: card, details: details)
        switch result {
        case .duplicateIgnored:
            return .result(dialog: "הרכישה כבר נרשמה — לא נוצרה כפילות.")
        case let .created(id, needsDetails, possibleDuplicate):
            let entry = Ledger(context: context).entry(id: id)
            await NotificationService.notifyPendingPurchase(entryID: id, merchant: entry?.title ?? "",
                                                            amount: entry.flatMap { $0.amount.isPositive ? $0.amount : nil },
                                                            needsDetails: needsDetails, possibleDuplicate: possibleDuplicate)
            await NotificationService.updateBadge(context: context)
            if needsDetails { return .result(dialog: "נוצרה עסקה ממתינה — חסרים פרטים להשלמה באפליקציה.") }
            return .result(dialog: "נרשמה רכישה ממתינה לאישור.")
        }
    }
}

/// הוספת הוצאה מהירה דרך Siri / קיצור דרך — נשמרת כמאושרת, כי המשתמש הקליד אותה בעצמו.
struct AddExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "הוספת הוצאה"
    static var description = IntentDescription("מוסיף הוצאה מאושרת בסכום ובתיאור שתאמר או תקליד.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "סכום")
    var amount: String

    @Parameter(title: "תיאור")
    var title: String

    @Parameter(title: "עסקית", default: false)
    var isBusiness: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let money = AmountParser.parse(amount)?.absolute, money.isPositive else {
            throw $amount.needsValueError("לא הצלחתי להבין את הסכום. מה הסכום?")
        }
        let context = Persistence.shared.mainContext
        let e = Entry(kind: .expense, status: .confirmed, amount: money, date: .now, title: title,
                      scope: isBusiness ? .business : .personal, source: .siri)
        context.insert(e)
        try context.save()
        return .result(dialog: "נשמרה הוצאה של \(MoneyFormat.string(money)) — \(title).")
    }
}

/// פתיחת תיבת העסקאות הממתינות
struct OpenPendingIntent: AppIntent {
    static var title: LocalizedStringResource = "פתיחת עסקאות ממתינות"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.selectedTab = .pending
        return .result()
    }
}

/// מצב כספי קצר — לשאול את Siri "כמה נשאר לי"
struct BalanceStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "מצב כספי"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let d = Ledger(context: Persistence.shared.mainContext).dashboard()
        return .result(dialog: "יתרה נוכחית \(MoneyFormat.string(d.currentBalance)). פנוי לשימוש \(MoneyFormat.string(d.safeToSpend)). תחזית לסוף החודש \(MoneyFormat.string(d.forecastEndOfMonth)) — זו הערכה, לא יתרת בנק.")
    }
}

struct KesefShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddExpenseIntent(), phrases: [
            "הוסף הוצאה ב\(.applicationName)",
            "Add expense in \(.applicationName)"
        ], shortTitle: "הוספת הוצאה", systemImageName: "minus.circle")
        AppShortcut(intent: OpenPendingIntent(), phrases: [
            "עסקאות ממתינות ב\(.applicationName)",
            "Open pending in \(.applicationName)"
        ], shortTitle: "עסקאות ממתינות", systemImageName: "tray")
        AppShortcut(intent: BalanceStatusIntent(), phrases: [
            "מצב כספי ב\(.applicationName)",
            "Money status in \(.applicationName)"
        ], shortTitle: "מצב כספי", systemImageName: "chart.bar")
        AppShortcut(intent: LogApplePayPurchaseIntent(), phrases: [
            "רשום רכישה ב\(.applicationName)",
            "Log Apple Pay purchase in \(.applicationName)"
        ], shortTitle: "רישום רכישת Apple Pay", systemImageName: "applelogo")
    }
}
