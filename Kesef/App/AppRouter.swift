import SwiftUI
import Observation

enum AppTab: Hashable {
    case home, transactions, pending, forecast, more
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

    func openPending(_ id: UUID) {
        selectedTab = .pending
        reviewEntryID = id
    }
}

enum QuickAddKind: String, Identifiable {
    case expense, income
    var id: String { rawValue }
}
