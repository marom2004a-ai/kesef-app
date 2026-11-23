import Foundation
import SwiftData

/// מיכל נתונים אחד משותף לאפליקציה ול-App Intents (שרצים באותו תהליך).
@MainActor
enum Persistence {
    static let shared: ModelContainer = {
        #if DEBUG
        if DemoMode.isOn {
            // מצב הדגמה: נתונים מומצאים בזיכרון בלבד — לא נוגע במאגר האמיתי
            let c = makeContainer(inMemory: true)
            DemoData.seed(c.mainContext)
            return c
        }
        #endif
        return makeContainer(inMemory: false)
    }()

    static func makeContainer(inMemory: Bool) -> ModelContainer {
        // בהפעלה הראשונה תיקיית Application Support עוד לא קיימת — יוצרים אותה מראש
        if !inMemory {
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        }
        let schema = Schema(KesefSchema.models)
        let config = ModelConfiguration("Kesef", schema: schema, isStoredInMemoryOnly: inMemory,
                                        allowsSave: true, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            Seed.ensureDefaults(in: container.mainContext)
            return container
        } catch {
            // אין להסתיר כשל: האפליקציה לא יכולה לעבוד בלי מאגר נתונים
            fatalError("פתיחת מאגר הנתונים נכשלה: \(error)")
        }
    }
}

// MARK: - שאילתות עזר

@MainActor
struct Ledger {
    let context: ModelContext

    func entries() -> [Entry] {
        (try? context.fetch(FetchDescriptor<Entry>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
    }
    func accounts(includeArchived: Bool = false) -> [Account] {
        let all = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]))) ?? []
        return includeArchived ? all : all.filter { !$0.isArchived }
    }
    func categories() -> [Category] {
        (try? context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))) ?? []
    }
    func recurring() -> [RecurringRule] {
        (try? context.fetch(FetchDescriptor<RecurringRule>(sortBy: [SortDescriptor(\.dayOfMonth)]))) ?? []
    }
    func budgets() -> [Budget] { (try? context.fetch(FetchDescriptor<Budget>())) ?? [] }
    func goals() -> [SavingsGoal] { (try? context.fetch(FetchDescriptor<SavingsGoal>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [] }
    func templates() -> [ExpenseTemplate] {
        (try? context.fetch(FetchDescriptor<ExpenseTemplate>(sortBy: [SortDescriptor(\.useCount, order: .reverse)]))) ?? []
    }
    func cardAliases() -> [CardAlias] { (try? context.fetch(FetchDescriptor<CardAlias>())) ?? [] }

    func entry(id: UUID) -> Entry? {
        var d = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func pendingCount() -> Int {
        let raw = EntryStatus.pendingReview.rawValue
        return (try? context.fetchCount(FetchDescriptor<Entry>(predicate: #Predicate { $0.statusRaw == raw }))) ?? 0
    }

    func partnerSettings() -> PartnerSettings? {
        let s = AppSettings.partner
        return s.isActive ? s : nil
    }

    func dashboard(now: Date = .now) -> DashboardSnapshot {
        DashboardEngine.build(now: now, accounts: accounts().map(\.snapshot), entries: entries().map(\.snapshot),
                              recurring: recurring().map(\.snapshot), partner: partnerSettings(),
                              monthlySavingsTarget: AppSettings.monthlySavingsTarget, reserve: AppSettings.reserve)
    }
}

// MARK: - ברירות מחדל

@MainActor
enum Seed {
    static func ensureDefaults(in context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0
        guard count == 0 else { return }
        var order = 0
        func add(_ name: String, _ scope: Scope, income: Bool = false, essential: Bool = true, _ symbol: String) {
            context.insert(Category(name: name, scope: scope, isIncome: income, isEssential: essential, symbol: symbol, sortOrder: order))
            order += 1
        }
        // הכנסות עסקיות
        add("אילוף ביתי", .business, income: true, "figure.walk")
        add("פנסיון אילוף", .business, income: true, "graduationcap")
        add("פנסיון רגיל", .business, income: true, "house")
        add("שירותים נוספים", .business, income: true, "sparkles")
        add("הכנסה עסקית אחרת", .business, income: true, "plus.circle")
        // הכנסות אישיות
        add("הכנסה אישית", .personal, income: true, "person.crop.circle")
        add("החזר / מתנה", .personal, income: true, "gift")
        // הוצאות אישיות
        add("מזון וסופר", .personal, "cart")
        add("מסעדות וקפה", .personal, essential: false, "fork.knife")
        add("קניות", .personal, essential: false, "bag")
        add("תחבורה ודלק", .personal, "fuelpump")
        add("בילויים", .personal, essential: false, "party.popper")
        add("בריאות", .personal, "cross.case")
        add("דיור ושכירות", .personal, "house.fill")
        add("חשבונות הבית", .personal, "bolt")
        add("ביטוחים", .personal, "shield")
        add("מנויים", .personal, essential: false, "repeat")
        add("הלוואות", .personal, "percent")
        add("אחר אישי", .personal, "ellipsis.circle")
        // הוצאות עסקיות
        add("מזון לכלבים", .business, "pawprint")
        add("פרסום ושיווק", .business, "megaphone")
        add("ציוד", .business, "shippingbox")
        add("שכירות עסק", .business, "building.2")
        add("רכב עסקי", .business, "car")
        add("ספקים", .business, "person.2")
        add("שירותים עסקיים", .business, "briefcase")
        add("וטרינר", .business, "stethoscope")
        add("אחר עסקי", .business, "ellipsis.circle")
        try? context.save()
    }
}

// MARK: - הגדרות (UserDefaults — אינן סודיות)

enum AppSettings {
    enum Key {
        static let defaultApplePayScope = "defaultApplePayScope"
        static let partnerName = "partnerName"
        static let partnerShareBP = "partnerShareBP"
        static let partnerBasis = "partnerBasis"
        static let reserveMinor = "reserveMinor"
        static let monthlySavingsMinor = "monthlySavingsMinor"
        static let faceIDEnabled = "faceIDEnabled"
        static let lockAfterSeconds = "lockAfterSeconds"
        static let billRemindersEnabled = "billRemindersEnabled"
        static let budgetAlertsEnabled = "budgetAlertsEnabled"
        static let lastApplePayIntentAt = "lastApplePayIntentAt"
        static let automationVerifiedAt = "automationVerifiedAt"
        static let budgetAlertBP = "budgetAlertBP"
        static let defaultApplePayAccount = "defaultApplePayAccount"
    }
    static var d: UserDefaults { .standard }

    /// ברירת המחדל לרכישות Apple Pay — "אישית" אם לא שונתה
    static var defaultApplePayScope: Scope {
        get { Scope(rawValue: d.string(forKey: Key.defaultApplePayScope) ?? "") ?? .personal }
        set { d.set(newValue.rawValue, forKey: Key.defaultApplePayScope) }
    }
    static var partner: PartnerSettings {
        PartnerSettings(name: d.string(forKey: Key.partnerName) ?? "שותף",
                        shareBasisPoints: d.integer(forKey: Key.partnerShareBP),
                        basis: PartnerBasis(rawValue: d.string(forKey: Key.partnerBasis) ?? "") ?? .profit)
    }
    static var reserve: Money { Money(minorUnits: Int64(d.integer(forKey: Key.reserveMinor))) }
    static var monthlySavingsTarget: Money { Money(minorUnits: Int64(d.integer(forKey: Key.monthlySavingsMinor))) }
    static var budgetAlertBasisPoints: Int { let v = d.integer(forKey: Key.budgetAlertBP); return v == 0 ? 8000 : v }
    static var billRemindersEnabled: Bool { d.object(forKey: Key.billRemindersEnabled) as? Bool ?? true }
    static var budgetAlertsEnabled: Bool { d.object(forKey: Key.budgetAlertsEnabled) as? Bool ?? true }
    static var defaultApplePayAccountID: UUID? { d.string(forKey: Key.defaultApplePayAccount).flatMap(UUID.init(uuidString:)) }
}
