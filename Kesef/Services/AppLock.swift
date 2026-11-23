import Foundation
import LocalAuthentication
import Observation

/// נעילת אפליקציה ב-Face ID / Touch ID / קוד המכשיר (LocalAuthentication הרשמי).
@Observable
@MainActor
final class AppLock {
    var isLocked: Bool
    var lastError: String?
    private var backgroundedAt: Date?

    init() {
        isLocked = UserDefaults.standard.bool(forKey: AppSettings.Key.faceIDEnabled)
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: AppSettings.Key.faceIDEnabled) }

    static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "קוד המכשיר"
        }
    }

    /// האם המכשיר תומך באימות (ביומטרי או קוד)
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// אימות פעיל כרגע — חלון Face ID מעביר את האפליקציה ל-inactive ובחזרה ל-active,
    /// ואסור שהחזרה הזו תנעל שוב או תפתח בקשת אימות שנייה (שמבטלת את הראשונה).
    private(set) var isAuthenticating = false

    func didEnterBackground() {
        backgroundedAt = .now
        // נעילה כבר ביציאה לרקע (אם אין זמן חסד) — כך המסך נעול לפני שחוזרים, בלי הבהוב של הנתונים
        if isEnabled && UserDefaults.standard.integer(forKey: AppSettings.Key.lockAfterSeconds) == 0 { isLocked = true }
    }

    func willEnterForeground() {
        guard isEnabled else { isLocked = false; backgroundedAt = nil; return }
        // חוזרים מחלון ה-Face ID עצמו — לא רלוונטי
        guard !isAuthenticating else { return }
        let grace = TimeInterval(UserDefaults.standard.integer(forKey: AppSettings.Key.lockAfterSeconds))
        if let t = backgroundedAt, Date.now.timeIntervalSince(t) >= grace { isLocked = true }
        // מאפסים — אחרת כל מעבר inactive→active (מרכז בקרה, Face ID) היה נועל מחדש לפי יציאה ישנה לרקע
        backgroundedAt = nil
    }

    func unlock() async {
        guard isEnabled else { isLocked = false; return }
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "ביטול"
        do {
            // deviceOwnerAuthentication = ביומטרי עם נפילה לקוד המכשיר
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "פתיחת נתוני הכספים שלך")
            if ok { isLocked = false; lastError = nil; backgroundedAt = nil }
        } catch let e as LAError {
            switch e.code {
            // ביטול ע״י המשתמש או ע״י המערכת (שיחה נכנסת, מעבר אפליקציה, האפליקציה עוד לא פעילה) — לא שגיאה, פשוט מנסים שוב
            case .userCancel, .systemCancel, .appCancel, .notInteractive:
                lastError = nil
            case .biometryLockout:
                lastError = "Face ID ננעל אחרי כמה ניסיונות. לחץ שוב כדי להיכנס עם קוד המכשיר."
            default:
                lastError = e.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// הפעלה/כיבוי — דורש אימות מוצלח כדי לוודא שהמכשיר תומך
    func setEnabled(_ on: Bool) async -> Bool {
        if !on { UserDefaults.standard.set(false, forKey: AppSettings.Key.faceIDEnabled); return true }
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            lastError = "במכשיר לא מוגדר קוד או Face ID."
            return false
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "הפעלת נעילה לאפליקציה")
            UserDefaults.standard.set(ok, forKey: AppSettings.Key.faceIDEnabled)
            return ok
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
