import SwiftUI
import Observation

/// הלשוניות: בית, קבלות ודוחות, תזרים וחיסכון, עוד.
/// תנועות וממתינות נגישות מהבית ומ"עוד"; הממתינות נפתחות כחלון.
enum AppTab: Hashable {
    case home, receipts, flow, more
}

/// ניווט גלובלי: פתיחת עסקה ממתינה מהתראה / מ-App Intent
@Observable
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    var selectedTab: AppTab = .home
    /// עסקה ממתינה לפתוח במסך האישור
    var reviewEntryID: UUID?
    var showQuickAdd: QuickAddKind?
    var showPending = false

    func openPending(_ id: UUID) {
        showPending = true
        reviewEntryID = id
    }
}

enum QuickAddKind: String, Identifiable {
    case expense, income
    var id: String { rawValue }
}
