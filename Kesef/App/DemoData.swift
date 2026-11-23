#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// מצב הדגמה לצילומי מסך בלבד (גרסת Debug). כל הנתונים כאן מומצאים.
/// הפעלה: פרמטרי הפעלה -KesefDemo -KesefScreen <name>
enum DemoMode {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-KesefDemo") }

    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-KesefScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// מסכים שמוצגים לבד (בלי סרגל הלשוניות)
    static let standalone: Set<String> = ["recurring", "budgets", "reports", "savings", "accounts", "automation", "settings", "vat", "import", "advisor"]

    @MainActor @ViewBuilder
    static func standaloneView(_ name: String) -> some View {
        switch name {
        case "recurring": RecurringListView()
        case "budgets": BudgetsView()
        case "reports": ReportsView()
        case "savings": SavingsView()
        case "accounts": AccountsView()
        case "automation": AutomationSetupView()
        case "vat": VatReportView()
        case "advisor": AdvisorChatView()
        case "import": CSVImportView()
        default: SettingsView()
        }
    }

    @MainActor
    static func applyNavigation(router: AppRouter, context: ModelContext) {
        switch screen {
        case "transactions": router.selectedTab = .transactions
        case "pending": router.selectedTab = .pending
        case "review":
            let raw = EntryStatus.pendingReview.rawValue
            let pending = (try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.statusRaw == raw }))) ?? []
            if let first = pending.first(where: { $0.source == .applePayShortcut }) { router.openPending(first.id) }
        case "forecast": router.selectedTab = .forecast
        case "more": router.selectedTab = .more
        case "expense": router.showQuickAdd = .expense
        case "income": router.showQuickAdd = .income
        default: router.selectedTab = .home
        }
    }
}

@MainActor
enum DemoData {
    static func seed(_ context: ModelContext, now: Date = .now) {
        let cal = FinanceCalendar.israel
        let d = UserDefaults.standard
        d.set(5000, forKey: AppSettings.Key.partnerShareBP)
        d.set("מרום", forKey: AppSettings.Key.partnerName)
        d.set(PartnerBasis.profit.rawValue, forKey: AppSettings.Key.partnerBasis)
        d.set(200_000, forKey: AppSettings.Key.reserveMinor)
        d.set(100_000, forKey: AppSettings.Key.monthlySavingsMinor)
        d.set(false, forKey: AppSettings.Key.faceIDEnabled)

        let cats = Ledger(context: context).categories()
        func cat(_ name: String) -> UUID? { cats.first { $0.name == name }?.id }
        func ils(_ s: Int64, _ ag: Int64 = 0) -> Money { Money(shekels: s, agorot: ag) }
        func daysAgo(_ n: Int, hour: Int = 12) -> Date {
            cal.calendar.date(byAdding: .hour, value: hour, to: cal.addDays(-n, to: cal.startOfDay(now))) ?? now
        }

        // חשבונות — היתרה הידועה נכונה ל-120 יום אחורה, כך שהתנועות ההיסטוריות נספרות
        let start = cal.addDays(-120, to: cal.startOfDay(now))
        let bank = Account(name: "בנק אישי", kind: .bank, scope: .personal, knownBalance: ils(6_200), balanceDate: start, sortOrder: 0)
        let biz = Account(name: "חשבון העסק", kind: .businessBank, scope: .business, knownBalance: ils(9_800), balanceDate: start, sortOrder: 1)
        let cash = Account(name: "מזומן", kind: .cash, scope: .personal, knownBalance: ils(450), balanceDate: start, sortOrder: 2)
        let visa = Account(name: "ויזה ••4821", kind: .creditCard, scope: .personal, knownBalance: .zero, balanceDate: start, billingDay: 10, sortOrder: 3)
        let save = Account(name: "קרן חירום", kind: .savings, scope: .personal, knownBalance: ils(14_000), balanceDate: start, sortOrder: 4)
        [bank, biz, cash, visa, save].forEach { context.insert($0) }
        d.set(visa.id.uuidString, forKey: AppSettings.Key.defaultApplePayAccount)

        func add(_ kind: EntryKind, _ amount: Money, _ title: String, _ date: Date, _ scope: Scope, _ category: String?,
                 _ account: Account, status: EntryStatus = .confirmed, fixed: Bool = false, certainty: Certainty = .high,
                 pm: PaymentMethod? = nil) {
            let e = Entry(kind: kind, status: status, amount: amount, date: date, title: title, scope: scope,
                          categoryID: category.flatMap(cat), accountID: account.id)
            e.createdAt = date
            e.isFixed = fixed
            e.certainty = certainty
            e.paymentMethod = pm ?? (kind == .expense ? (account.kind == .creditCard ? .creditCard : .bankTransfer) : .bit)
            context.insert(e)
        }

        // 4 חודשים של היסטוריה — הכנסות משתנות של עצמאי
        let monthlyIncome: [(Int64, Int64, Int64)] = [(7_800, 5_400, 2_100), (11_200, 6_900, 2_600), (6_300, 4_100, 1_500), (9_600, 7_200, 2_300)]
        for (i, m) in monthlyIncome.enumerated() {
            let base = 118 - i * 30
            add(.income, ils(m.0), "לקוחות אילוף ביתי", daysAgo(base - 3), .business, "אילוף ביתי", biz)
            add(.income, ils(m.1), "פנסיון — לינות החודש", daysAgo(base - 10), .business, "פנסיון רגיל", biz)
            add(.income, ils(m.2), "פנסיון אילוף — משפחת כהן", daysAgo(base - 18), .business, "פנסיון אילוף", biz)
            add(.expense, ils(1_380), "מזון לכלבים — ספק", daysAgo(base - 5), .business, "מזון לכלבים", biz, fixed: true)
            add(.expense, ils(650 + Int64(i) * 90), "קמפיין פייסבוק", daysAgo(base - 12), .business, "פרסום ושיווק", visa)
            add(.expense, ils(4_200), "שכירות דירה", daysAgo(base - 1), .personal, "דיור ושכירות", bank, fixed: true)
            add(.expense, ils(1_950 + Int64(i) * 120), "שופרסל", daysAgo(base - 7), .personal, "מזון וסופר", visa)
            add(.expense, ils(420 + Int64(i) * 160), "ארוחות בחוץ", daysAgo(base - 15), .personal, "מסעדות וקפה", visa)
            add(.expense, ils(510), "דלק", daysAgo(base - 9), .personal, "תחבורה ודלק", visa)
            add(.expense, ils(320), "חשמל ומים", daysAgo(base - 20), .personal, "חשבונות הבית", bank, fixed: true)
            add(.expense, ils(240), "וטרינר", daysAgo(base - 22), .business, "וטרינר", biz)
            add(.cardPayment, ils(3_100 + Int64(i) * 200), "חיוב ויזה", daysAgo(base - 10), .personal, nil, bank)
        }
        // סילוק כרטיס צריך חשבון יעד
        for e in Ledger(context: context).entries() where e.kind == .cardPayment { e.toAccountID = visa.id }

        // החודש הנוכחי
        add(.income, ils(2_400), "אילוף ביתי — 3 מפגשים", daysAgo(4), .business, "אילוף ביתי", biz)
        add(.expense, ils(612, 30), "רמי לוי", daysAgo(3), .personal, "מזון וסופר", visa)
        add(.expense, ils(98), "קפה ומאפה", daysAgo(2), .personal, "מסעדות וקפה", visa)
        add(.expense, ils(349), "רצועות וקולרים", daysAgo(1), .business, "ציוד", visa)
        add(.income, ils(900), "פנסיון — משפחת לוי", cal.addDays(3, to: now), .business, "פנסיון רגיל", biz, status: .planned, certainty: .high)
        add(.income, ils(1_200), "קורס חברים על 4 (2/3)", cal.addDays(6, to: now), .business, "פנסיון אילוף", biz, status: .planned, certainty: .medium)
        add(.income, ils(1_500), "לקוח חדש — אילוף", cal.addDays(12, to: now), .business, "אילוף ביתי", biz, status: .planned, certainty: .low)

        // חיובים קבועים
        func rule(_ title: String, _ amount: Money, _ day: Int, _ scope: Scope, _ category: String, _ account: Account,
                  freq: Frequency = .monthly, variable: Bool = false) {
            let r = RecurringRule(title: title, amount: amount, frequency: freq, dayOfMonth: day,
                                  startDate: cal.addMonths(-6, to: now), scope: scope)
            r.categoryID = cat(category); r.accountID = account.id; r.isVariableAmount = variable
            r.createdAt = now; r.autoCreatePending = false
            context.insert(r)
        }
        rule("שכירות דירה", ils(4_200), 1, .personal, "דיור ושכירות", bank)
        rule("מזון לכלבים — ספק", ils(1_380), 20, .business, "מזון לכלבים", biz)
        rule("ביטוח רכב", ils(385), 15, .personal, "ביטוחים", bank)
        rule("הלוואת רכב", ils(950), 10, .personal, "הלוואות", bank)
        rule("ספוטיפיי", ils(22, 90), 5, .personal, "מנויים", visa)
        rule("חשמל ומים", ils(320), 22, .personal, "חשבונות הבית", bank, freq: .bimonthly, variable: true)

        // תקציבים ויעד
        for (name, limit) in [("מזון וסופר", 2_500), ("מסעדות וקפה", 600), ("פרסום ושיווק", 1_000), ("קניות", 800)] {
            if let id = cat(name) { context.insert(Budget(categoryID: id, limit: ils(Int64(limit)))) }
        }
        let goal = SavingsGoal(title: "קרן חירום — 3 חודשים", target: ils(30_000), monthlyContribution: ils(1_000),
                               targetDate: cal.addMonths(14, to: now))
        goal.saved = ils(14_000); goal.accountID = save.id
        context.insert(goal)

        try? context.save()

        // רכישת Apple Pay שממתינה לאישור — דרך אותו שירות שה-App Intent משתמש בו
        _ = try? PendingTransactionService(context: context)
            .ingestApplePay(amountText: "₪186.40", merchant: "סופר יוחננוף נהריה", cardLabel: "Visa ••4821", markAutomationRun: true)
        _ = try? PendingTransactionService(context: context)
            .ingestApplePay(amountText: "₪0.00", merchant: "", cardLabel: "Visa ••4821", markAutomationRun: false)
    }
}
#endif
