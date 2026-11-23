import SwiftUI
import SwiftData

struct MoreView: View {
    var body: some View {
        List {
            Section("תכנון") {
                NavigationLink { RecurringListView() } label: { Label("חיובים קבועים", systemImage: "repeat") }
                NavigationLink { BudgetsView() } label: { Label("תקציבים", systemImage: "chart.pie") }
                NavigationLink { SavingsView() } label: { Label("חיסכון, יעדים והמלצות", systemImage: "leaf") }
                NavigationLink { ReportsView() } label: { Label("דוחות וניתוח", systemImage: "chart.bar.xaxis") }
            }
            Section("נתונים") {
                NavigationLink { AccountsView() } label: { Label("חשבונות וכרטיסים", systemImage: "building.columns") }
                NavigationLink { CategoriesView() } label: { Label("קטגוריות", systemImage: "tag") }
                NavigationLink { CSVImportView() } label: { Label("ייבוא CSV מהבנק / אשראי", systemImage: "square.and.arrow.down") }
                NavigationLink { BackupView() } label: { Label("גיבוי ושחזור", systemImage: "externaldrive") }
            }
            Section("הגדרות") {
                NavigationLink { AutomationSetupView() } label: { Label("אוטומציית Apple Pay", systemImage: "wallet.pass") }
                NavigationLink { PartnerSettingsView() } label: { Label("שותף וחלוקת רווחים", systemImage: "person.2") }
                NavigationLink { SettingsView() } label: { Label("הגדרות כלליות ואבטחה", systemImage: "gearshape") }
            }
        }
        .navigationTitle("עוד")
    }
}

struct SettingsView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.Key.defaultApplePayScope) private var defaultScopeRaw = Scope.personal.rawValue
    @AppStorage(AppSettings.Key.faceIDEnabled) private var faceID = false
    @AppStorage(AppSettings.Key.lockAfterSeconds) private var lockAfter = 0
    @AppStorage(AppSettings.Key.billRemindersEnabled) private var billReminders = true
    @AppStorage(AppSettings.Key.budgetAlertsEnabled) private var budgetAlerts = true
    @AppStorage(AppSettings.Key.reserveMinor) private var reserveMinor = 0
    @AppStorage(AppSettings.Key.monthlySavingsMinor) private var savingsMinor = 0
    @State private var reserveText = ""
    @State private var savingsText = ""
    @State private var notifStatus = "בודק…"
    @State private var showErase = false
    @State private var showErase2 = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("סיווג ברירת מחדל לרכישת Apple Pay", selection: $defaultScopeRaw) {
                    Text("הוצאה אישית").tag(Scope.personal.rawValue)
                    Text("הוצאה עסקית").tag(Scope.business.rawValue)
                }
            } footer: { Text("ברירת המחדל המקורית היא 'אישית'. אפשר תמיד לשנות בכל רכישה במסך האישור.") }

            Section("תכנון") {
                LabeledContent("כרית ביטחון (לא לגעת)") {
                    TextField("0", text: $reserveText).keyboardType(.decimalPad).multilineTextAlignment(.leading)
                        .onSubmit(saveNumbers)
                }
                LabeledContent("יעד חיסכון חודשי") {
                    TextField("0", text: $savingsText).keyboardType(.decimalPad).multilineTextAlignment(.leading)
                        .onSubmit(saveNumbers)
                }
                Button("שמירת סכומים", action: saveNumbers)
                Text("שני הסכומים מופחתים מ'סכום פנוי לשימוש' במסך הבית.").font(.caption).foregroundStyle(.secondary)
            }

            Section("אבטחה") {
                Toggle("נעילה עם \(AppLock.biometryName)", isOn: Binding(get: { faceID }, set: { on in
                    Task { let ok = await lock.setEnabled(on); faceID = on && ok }
                }))
                .disabled(!AppLock.canAuthenticate)
                if faceID {
                    Picker("נעל אחרי", selection: $lockAfter) {
                        Text("מיד").tag(0); Text("דקה").tag(60); Text("5 דקות").tag(300)
                    }
                }
                if let e = lock.lastError { Text(e).font(.caption).foregroundStyle(Theme.expense) }
                Text("הנתונים נשמרים רק במכשיר, במאגר SwiftData בתוך תיקיית האפליקציה, ומוגנים בהצפנת הקבצים המובנית של iOS (Data Protection) כשמוגדר קוד למכשיר. האפליקציה לא מוסיפה הצפנה משלה, לא שומרת מספרי כרטיס מלאים או סיסמאות בנק, ולא שולחת מידע לשום שרת.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("התראות") {
                LabeledContent("הרשאת התראות", value: notifStatus)
                Button("בקשת הרשאה להתראות") {
                    Task { _ = await NotificationService.requestAuthorization(); await refreshStatus() }
                }
                Toggle("תזכורות לפני חיובים קבועים", isOn: $billReminders)
                    .onChange(of: billReminders) { _, _ in Task { await NotificationService.rescheduleBillReminders(context: context) } }
                Toggle("התראות תקציב", isOn: $budgetAlerts)
            }

            Section {
                Button("מחיקת כל הנתונים", role: .destructive) { showErase = true }
                if let message { Text(message).font(.caption) }
            } footer: { Text("מומלץ ליצור גיבוי לפני מחיקה.") }
        }
        .navigationTitle("הגדרות")
        .onAppear {
            reserveText = reserveMinor == 0 ? "" : MoneyFormat.editString(Money(minorUnits: Int64(reserveMinor)))
            savingsText = savingsMinor == 0 ? "" : MoneyFormat.editString(Money(minorUnits: Int64(savingsMinor)))
        }
        .task { await refreshStatus() }
        .confirmationDialog("למחוק את כל הנתונים?", isPresented: $showErase, titleVisibility: .visible) {
            Button("כן, להמשיך", role: .destructive) { showErase2 = true }
        } message: { Text("כל החשבונות, התנועות, החיובים, התקציבים והיעדים יימחקו מהמכשיר.") }
        .alert("אישור אחרון", isPresented: $showErase2) {
            Button("מחיקה סופית", role: .destructive) {
                do { try BackupService(context: context).eraseAll(); message = "כל הנתונים נמחקו." }
                catch { message = "המחיקה נכשלה: \(error.localizedDescription)" }
            }
            Button("ביטול", role: .cancel) {}
        } message: { Text("לא ניתן לשחזר אלא מקובץ גיבוי.") }
    }

    private func saveNumbers() {
        reserveMinor = Int(AmountParser.parse(reserveText)?.absolute.minorUnits ?? 0)
        savingsMinor = Int(AmountParser.parse(savingsText)?.absolute.minorUnits ?? 0)
        message = "נשמר."
    }

    private func refreshStatus() async {
        switch await NotificationService.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: notifStatus = "מאושרת"
        case .denied: notifStatus = "חסומה — יש לאשר בהגדרות iOS"
        default: notifStatus = "טרם התבקשה"
        }
    }
}

struct PartnerSettingsView: View {
    @AppStorage(AppSettings.Key.partnerName) private var name = "שותף"
    @AppStorage(AppSettings.Key.partnerShareBP) private var shareBP = 0
    @AppStorage(AppSettings.Key.partnerBasis) private var basisRaw = PartnerBasis.profit.rawValue
    @Query private var entries: [Entry]

    var body: some View {
        let cal = FinanceCalendar.israel
        let settings = PartnerSettings(name: name, shareBasisPoints: shareBP, basis: PartnerBasis(rawValue: basisRaw) ?? .profit)
        let st = PartnerEngine.statement(entries: entries.map(\.snapshot), period: cal.monthRange(.now), settings: settings)
        Form {
            Section {
                TextField("שם השותף", text: $name)
                Stepper("חלק השותף: \(shareBP / 100)%", value: $shareBP, in: 0...10_000, step: 500)
                Picker("החלוקה מחושבת", selection: $basisRaw) {
                    ForEach(PartnerBasis.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } footer: {
                Text("0% = אין שותף. החלוקה חלה רק על הכנסות והוצאות שסווגו כעסקיות. הפקדה לחשבון אינה נחשבת אוטומטית ככסף אישי זמין.")
            }
            if shareBP > 0 {
                Section("החודש") {
                    LabeledContent("בסיס החישוב") { MoneyText(money: st.base) }
                    LabeledContent("חלק השותף") { MoneyText(money: st.share) }
                    LabeledContent("שולם לשותף") { MoneyText(money: st.paid) }
                    LabeledContent("נותר לשלם") { MoneyText(money: st.owed, font: .headline, colored: st.owed.isNegative) }
                    Text("תשלום לשותף נרשם כתנועה מסוג 'תשלום לשותף'. משיכה שלך מהעסק נרשמת כ'משיכת בעלים' — העברה, לא הוצאה.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("שותף")
    }
}
