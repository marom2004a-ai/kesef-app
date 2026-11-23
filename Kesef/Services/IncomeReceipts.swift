import Foundation

/// מעקב אחרי הכנסות עסקיות שעוד לא הופקה להן קבלה.
/// הכנסה "מכוסה" אם הופק לה מסמך ב-morning (externalRef "morning:…") או שסומן שהקבלה הופקה ידנית ("receipt:manual").
/// נספרות רק הכנסות שהוזנו ידנית מאז שהמעקב התחיל — לא היסטוריה ולא ייבוא מדוחות.
enum IncomeReceipts {
    static let sinceKey = "incomeReceiptsTrackingSince"
    static let manualRef = "receipt:manual"

    static func startTrackingIfNeeded() {
        if UserDefaults.standard.object(forKey: sinceKey) == nil {
            UserDefaults.standard.set(Date.now.timeIntervalSinceReferenceDate, forKey: sinceKey)
        }
    }

    static var since: Date {
        Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: sinceKey))
    }

    static func hasReceipt(_ e: Entry) -> Bool {
        guard let ref = e.externalRef else { return false }
        return ref.hasPrefix("morning:") || ref.hasPrefix("receipt:")
    }

    static func isAwaiting(_ e: Entry, since: Date) -> Bool {
        e.scope == .business && e.kind == .income && e.status == .confirmed
            && (e.source == .manual || e.source == .incomingPayment)
            && e.createdAt >= since && !hasReceipt(e)
    }
}
