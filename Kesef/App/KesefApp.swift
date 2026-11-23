import SwiftUI
import SwiftData
import UserNotifications

@main
struct KesefApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var lock: AppLock

    init() {
        AppSettings.registerDefaults()
        _lock = State(initialValue: AppLock())
        Self.applyAppearance()
        IncomeReceipts.startTrackingIfNeeded()
    }
    @Environment(\.scenePhase) private var scenePhase

    /// סרגל ניווט ולשוניות בגוון הכהה-החם של האפליקציה
    private static func applyAppearance() {
        let bg = UIColor(red: 0.071, green: 0.067, blue: 0.063, alpha: 1)
        let text = UIColor(red: 0.953, green: 0.922, blue: 0.867, alpha: 1)
        let gold = UIColor(red: 0.910, green: 0.714, blue: 0.361, alpha: 1)
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bg
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: text]
        nav.largeTitleTextAttributes = [.foregroundColor: text,
                                        .font: UIFont.systemFont(ofSize: 32, weight: .bold).rounded]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = bg
        tab.shadowColor = UIColor(red: 0.16, green: 0.157, blue: 0.141, alpha: 1)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.selected.iconColor = gold
            item.selected.titleTextAttributes = [.foregroundColor: gold]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppRouter.shared)
                .environment(lock)
                // עברית מלאה מימין לשמאל, תאריכים ומספרים בתבנית ישראלית
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
                .environment(\.calendar, FinanceCalendar.israel.calendar)
                .environment(\.timeZone, FinanceCalendar.israel.calendar.timeZone)
                // מראה כהה ויוקרתי עם זהב — קבוע, לא תלוי בהגדרת המכשיר
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
        .modelContainer(Persistence.shared)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: lock.didEnterBackground()
            case .active:
                lock.willEnterForeground()
                Task { await AppLifecycle.refresh() }
            default: break
            }
        }
    }
}

/// משימות שרצות בכל חזרה לאפליקציה
@MainActor
enum AppLifecycle {
    static func refresh() async {
        let context = Persistence.shared.mainContext
        _ = try? LedgerService(context: context).postDueRecurring()
        await NotificationService.updateBadge(context: context)
        await NotificationService.rescheduleBillReminders(context: context)
        await NotificationService.checkBudgets(context: context)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { NotificationService.registerCategories() }
        return true
    }

    // התראה כשהאפליקציה פתוחה — להציג באנר
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge, .list]
    }

    // לחיצה על התראה או על פעולה בה
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let idString = info["entryID"] as? String, let id = UUID(uuidString: idString) else { return }
        await Self.handle(entryID: id, action: response.actionIdentifier)
    }

    @MainActor
    static func handle(entryID id: UUID, action: String) async {
        let context = Persistence.shared.mainContext
        if action == NotificationService.confirmPersonalAction,
           let entry = Ledger(context: context).entry(id: id), entry.status == .pendingReview {
            let ok = (try? PendingTransactionService(context: context).quickConfirm(entry)) ?? false
            if !ok { AppRouter.shared.openPending(id) }
        } else {
            AppRouter.shared.openPending(id)
        }
        await NotificationService.updateBadge(context: context)
    }
}

private extension UIFont {
    /// גרסה מעוגלת של הגופן (SF Rounded) לכותרות
    var rounded: UIFont {
        guard let d = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: d, size: pointSize)
    }
}
