import SwiftUI
import SwiftData

/// הוראות הגדרה לאוטומציית Wallet ב-Shortcuts, מצב אמיתי (לא מוצגת כפעילה לפני שרצה), ובדיקה מקומית.
struct AutomationSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @AppStorage(AppSettings.Key.lastApplePayIntentAt) private var lastIntent: Double = 0
    @Query private var aliases: [CardAlias]
    @Query private var accounts: [Account]
    @State private var notifStatus = ""
    @State private var testMessage: String?

    var body: some View {
        List {
            Section("מצב") {
                if lastIntent == 0 {
                    Label("האוטומציה עוד לא הופעלה אף פעם", systemImage: "circle.dashed")
                        .foregroundStyle(Theme.warning)
                    Text("אחרי ההגדרה, בצע רכישת Apple Pay (או הרץ את הקיצור ידנית) כדי לוודא שהיא עובדת.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("הפעולה הופעלה מ-Shortcuts לאחרונה: \(Fmt.dateTime(Date(timeIntervalSinceReferenceDate: lastIntent)))",
                          systemImage: "checkmark.circle.fill").foregroundStyle(Theme.income)
                }
                LabeledContent("הרשאת התראות", value: notifStatus)
                if notifStatus != "מאושרת" {
                    Button("אישור התראות") { Task { _ = await NotificationService.requestAuthorization(); await refresh() } }
                }
            }

            Section("מגבלות חשובות של iOS") {
                bullet("האוטומציה פועלת רק בתשלום Apple Pay פיזי (הצמדת האייפון/השעון למסוף). רכישות אונליין ובתוך אפליקציות בדרך כלל לא מפעילות אותה.")
                bullet("iOS מעביר רק: סכום, שם בית העסק וכרטיס. אין מזהה עסקה — לכן הכפילויות נבדקות לפי סכום + בית עסק + כרטיס + חלון זמן.")
                bullet("לפעמים הסכום מגיע 0 או שם בית העסק ריק, ולפעמים האוטומציה לא רצה בכלל (תלוי בחברת האשראי). עסקה עם פרטים חסרים נפתחת כממתינה להשלמה.")
                bullet("אין לאפליקציה גישה ישירה לרכישות שלך ב-Wallet. כל מה שלא הגיע דרך האוטומציה צריך להוסיף ידנית או לייבא מ-CSV.")
            }

            Section("הגדרה — פעם אחת") {
                step(1, "פתח את אפליקציית קיצורים (Shortcuts) ← לשונית 'אוטומציה'.")
                step(2, "לחץ + ← גלול ובחר 'ארנק' (Wallet / Transaction).")
                step(3, "בחר את הכרטיסים שבהם אתה משלם ב-Apple Pay. אל תסנן לפי קטגוריות (מדווח שזה מונע הפעלה).")
                step(4, "בחר 'הפעל מיד' (Run Immediately) וכבה 'הודע בעת הפעלה' אם רוצים. לחץ 'הבא'.")
                step(5, "בחר 'יצירת קיצור חדש' (או 'אוטומציה ריקה חדשה') ← חפש 'הכסף שלי' ← 'רישום רכישת Apple Pay'.")
                step(6, "לחץ על 'פרטי עסקה' ← בפס שמעל המקלדת בחר 'קלט של קיצור'. זה הכול — האפליקציה מחלצת את הסכום, בית העסק והכרטיס.")
                step(7, "אם iOS מאפשר לבחור שדות של העסקה (סכום/סוחר/כרטיס) — אפשר גם למלא את השדות הנפרדים, אבל זה לא חובה.")
                step(8, "לחץ 'סיום'. בפעם הראשונה iOS עשוי לבקש 'אפשר תמיד' — אשר.")
                step(9, "בהגדרות iOS ← התראות ← ודא שהתראות האפליקציה פעילות, ושהתראות ארנק לא בסיכום מתוזמן.")
            }

            Section("בדיקה") {
                Button("צור עסקת בדיקה ממתינה (מקומית)") { createTest() }
                if let testMessage { Text(testMessage).font(.caption) }
                Text("הבדיקה המקומית בודקת את מסך האישור וההתראה בלבד — היא לא מסמנת את האוטומציה כפעילה. כדי לבדוק את האוטומציה עצמה: בקיצורים, הרץ את הפעולה ידנית עם ערכים לדוגמה, או בצע רכישת Apple Pay אמיתית קטנה.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("שיוך כרטיסים לחשבונות") {
                if aliases.isEmpty {
                    Text("כשתאשר רכישה ותבחר חשבון, אפשר לסמן 'לשייך את הכרטיס לחשבון תמיד'. השיוכים יופיעו כאן.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(aliases) { a in
                    LabeledContent(a.walletLabel, value: accounts.first { $0.id == a.accountID }?.name ?? "חשבון שנמחק")
                        .swipeActions { Button("מחיקה", role: .destructive) { context.delete(a); try? context.save() } }
                }
                Text("נשמר רק השם שמגיע מ-Wallet (למשל 'Visa ••1234'). מספר כרטיס מלא לא נשמר לעולם.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("אוטומציית Apple Pay")
        .task { await refresh() }
    }

    private func bullet(_ s: String) -> some View {
        Label { Text(s).font(.subheadline) } icon: { Image(systemName: "info.circle").foregroundStyle(Theme.forecast) }
    }
    private func step(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 22, height: 22).background(Theme.accent.opacity(0.15), in: Circle())
            Text(s).font(.subheadline)
        }
    }

    private func refresh() async {
        switch await NotificationService.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: notifStatus = "מאושרת"
        case .denied: notifStatus = "חסומה"
        default: notifStatus = "טרם התבקשה"
        }
    }

    private func createTest() {
        do {
            let r = try PendingTransactionService(context: context)
                .ingestApplePay(amountText: "₪1.00", merchant: "עסקת בדיקה", cardLabel: "בדיקה", markAutomationRun: false)
            if case let .created(id, needs, dup) = r {
                Task {
                    await NotificationService.notifyPendingPurchase(entryID: id, merchant: "עסקת בדיקה", amount: Money(shekels: 1),
                                                                    needsDetails: needs, possibleDuplicate: dup)
                    await NotificationService.updateBadge(context: context)
                }
                testMessage = "נוצרה עסקת בדיקה בתיבת הממתינות. אפשר לדחות אותה אחרי הבדיקה."
                router.openPending(id)
            } else {
                testMessage = "עסקת בדיקה זהה נוצרה לפני פחות מ-3 דקות — לא נוצרה כפילות (כך גם בהפעלה חוזרת של האוטומציה)."
            }
        } catch { testMessage = "שגיאה: \(error.localizedDescription)" }
    }
}
