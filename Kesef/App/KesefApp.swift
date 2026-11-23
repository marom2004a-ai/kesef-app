import SwiftUI
import SwiftData
import UserNotifications

@main
struct KesefApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

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
