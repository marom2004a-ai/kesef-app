import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Entry> { $0.statusRaw == "pendingReview" }) private var pending: [Entry]

    var body: some View {
        @Bindable var router = router
        ZStack {
            TabView(selection: $router.selectedTab) {
                NavigationStack { HomeView() }
                    .tabItem { Label("בית", systemImage: "house.fill") }
                    .tag(AppTab.home)
                NavigationStack { TransactionsView() }
                    .tabItem { Label("תנועות", systemImage: "list.bullet.rectangle") }
                    .tag(AppTab.transactions)
                NavigationStack { PendingInboxView() }
                    .tabItem { Label("ממתינות", systemImage: "tray.full.fill") }
                    .badge(pending.count)
                    .tag(AppTab.pending)
                NavigationStack { ForecastView() }
                    .tabItem { Label("תזרים", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(AppTab.forecast)
                NavigationStack { MoreView() }
                    .tabItem { Label("עוד", systemImage: "square.grid.2x2.fill") }
                    .tag(AppTab.more)
            }
            .sheet(item: $router.showQuickAdd) { kind in
                NavigationStack { EntryEditorView(kind: kind == .income ? .income : .expense) }
            }

            // הסתרת נתונים במעבר בין אפליקציות
            if scenePhase != .active && lock.isEnabled {
                PrivacyCover()
            }
            if lock.isLocked {
                LockScreen()
            }
        }
        .task { await AppLifecycle.refresh() }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
        }
    }
}

struct LockScreen: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
                Text("הנתונים נעולים").font(.title2.bold())
                Text("כדי לראות את המידע הפיננסי שלך יש לאמת זהות.").foregroundStyle(.secondary)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("פתח עם \(AppLock.biometryName)", systemImage: "faceid")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
                if let e = lock.lastError { Text(e).font(.footnote).foregroundStyle(Theme.expense) }
            }
            .padding()
        }
        .task { await lock.unlock() }
    }
}
