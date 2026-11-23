import SwiftUI
import SwiftData

/// הפקת קבלה / חשבונית מס-קבלה דרך morning, ורישום ההכנסה אוטומטית.
struct IssueReceiptView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @AppStorage(MorningService.envKey) private var envRaw = MorningService.Environment.sandbox.rawValue
    @AppStorage(AppSettings.Key.vatRegistered) private var vatRegistered = true

    @State private var docType: MorningDocType = .taxInvoiceReceipt
    @State private var clientName = ""
    @State private var clientEmail = ""
    @State private var clientPhone = ""
    @State private var categoryID: UUID?
    @State private var itemDescription = ""
    @State private var amountText = ""
    @State private var payment: MorningPaymentMethod = .bit
    @State private var date = Date.now
    @State private var accountID: UUID?
    @State private var remarks = ""
    @State private var confirming = false
    @State private var sending = false
    @State private var error: String?
    @State private var created: MorningService.CreatedDocument?
    @State private var showSettings = false

    private var env: MorningService.Environment { MorningService.Environment(rawValue: envRaw) ?? .sandbox }
    private var amount: Money? { AmountParser.parse(amountText)?.absolute }
    private var incomeCategories: [Category] { categories.filter { $0.scope == .business && $0.isIncome && !$0.isArchived } }

    private var draft: MorningDocumentDraft {
        MorningDocumentDraft(type: docType, clientName: clientName, clientEmail: clientEmail, clientPhone: clientPhone,
                             itemDescription: itemDescription, amountIncludingVAT: amount ?? .zero, vatExempt: !vatRegistered,
                             payment: payment, date: date, remarks: remarks)
    }

    var body: some View {
        Group {
            if !MorningService.isConfigured(env) {
                EmptyStateView(symbol: "doc.badge.gearshape", title: "צריך לחבר את morning",
                               message: "כדי להפיק קבלות רשמיות מחברים את החשבון שלך ב-morning (חשבונית ירוקה) עם מפתח API.",
                               actionTitle: "הגדרת חיבור") { showSettings = true }
            } else if let created { successView(created) } else { form }
        }
        .navigationTitle("הפקת קבלה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { MorningSettingsView() } }
        .onAppear {
            if accountID == nil { accountID = accounts.first { $0.kind == .businessBank }?.id }
            if !vatRegistered && docType == .taxInvoiceReceipt { docType = .receipt }
        }
    }

    private var form: some View {
        Form {
            Section {
                Label(env == .sandbox ? "מצב ניסיון — המסמך לא אמיתי ולא נרשמת הכנסה" : "מצב אמיתי — מפיק מסמך מס רשמי",
                      systemImage: env == .sandbox ? "testtube.2" : "checkmark.seal.fill")
                    .foregroundStyle(env == .sandbox ? Theme.warning : Theme.income)
                    .font(.subheadline.weight(.semibold))
                Picker("סוג מסמך", selection: $docType) {
                    ForEach(MorningDocType.allCases) { Text($0.label).tag($0) }
                }
            }
            if let error { Section { ErrorBanner(message: error) } }
            Section("לקוח") {
                TextField("שם הלקוח (חובה)", text: $clientName)
                TextField("מייל — המסמך יישלח אליו (לא חובה)", text: $clientEmail)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
                TextField("נייד (לא חובה)", text: $clientPhone).keyboardType(.phonePad)
            }
            Section("שירות וסכום") {
                Picker("שירות", selection: $categoryID) {
                    Text("בחר").tag(UUID?.none)
                    ForEach(incomeCategories) { Text($0.name).tag(Optional($0.id)) }
                }
                .onChange(of: categoryID) { _, id in
                    if itemDescription.isEmpty, let c = incomeCategories.first(where: { $0.id == id }) { itemDescription = c.name }
                }
                TextField("תיאור בשורת המסמך", text: $itemDescription)
                AmountField(text: $amountText)
                if vatRegistered, let a = amount, a.isPositive {
                    let vat = VatEngine.vatIncluded(in: a, rateBasisPoints: AppSettings.vat.rateBasisPoints)
                    Text("כולל מע״מ \(MoneyFormat.string(vat)) · לפני מע״מ \(MoneyFormat.string(a - vat))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if docType.recordsPayment {
                Section("תשלום") {
                    Picker("אמצעי תשלום", selection: $payment) {
                        ForEach(MorningPaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                    DatePicker("תאריך", selection: $date, displayedComponents: .date)
                    AccountPicker(title: "נכנס לחשבון", selection: $accountID)
                }
            }
            Section { TextField("הערות במסמך (לא חובה)", text: $remarks, axis: .vertical) }
            Section {
                Button { validateAndConfirm() } label: {
                    HStack {
                        if sending { ProgressView() }
                        Text(sending ? "מפיק…" : "הפקת \(docType.label)").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending)
            } footer: {
                Text("המסמך מופק במערכת morning (תוכנה רשומה), נחתם דיגיטלית ונשלח ללקוח במייל אם הוזן. אחרי ההפקה ההכנסה נרשמת כאן אוטומטית — כולל מע״מ וחלוקה עם השותף.")
            }
        }
        .confirmationDialog("להפיק \(docType.label) רשמי?", isPresented: $confirming, titleVisibility: .visible) {
            Button(env == .production ? "הפקה — מסמך רשמי" : "הפקת מסמך ניסיון") { issue() }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("\(clientName) · \(MoneyFormat.string(amount ?? .zero)) · \(payment.label)" +
                 (env == .production ? "\nמסמך מס רשמי לא ניתן למחיקה — רק ביטול באמצעות מסמך זיכוי." : ""))
        }
    }

    private func successView(_ doc: MorningService.CreatedDocument) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Theme.income)
            Text("\(docType.label) מס׳ \(doc.number) הופק").font(.title2.bold()).multilineTextAlignment(.center)
            if env == .sandbox { Text("מסמך ניסיון — לא נרשמה הכנסה.").foregroundStyle(Theme.warning) }
            else if docType.recordsPayment { Text("ההכנסה נרשמה בתנועות, כולל מע״מ וחלוקה עם השותף.").foregroundStyle(.secondary) }
            if doc.taxAuthorityError != 0 {
                Label("רשות המסים החזירה שגיאה (\(doc.taxAuthorityError)) על מספר ההקצאה. בדוק את המסמך ב-morning.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning).font(.footnote)
            }
            if let url = doc.url {
                ShareLink(item: url) { Label("שיתוף המסמך (וואטסאפ / מייל)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent)
                Link(destination: url) { Label("פתיחת המסמך", systemImage: "doc.richtext") }
            }
            Button("מסמך חדש") { reset() }.padding(.top)
        }
        .padding()
    }

    private func validateAndConfirm() {
        do { try draft.validate(); error = nil; confirming = true }
        catch let e as MorningDocumentDraft.ValidationError {
            switch e {
            case .missingClient: error = "חסר שם לקוח."
            case .missingDescription: error = "חסר תיאור לשורת המסמך."
            case .invalidAmount: error = "הזן סכום גדול מאפס."
            case .invalidEmail: error = "כתובת המייל לא תקינה."
            }
        } catch { self.error = error.localizedDescription }
    }

    private func issue() {
        sending = true
        let d = draft
        Task {
            do {
                let doc = try await MorningService.createDocument(d)
                _ = try MorningService.recordIncome(context: context, draft: d, doc: doc, categoryID: categoryID, accountID: accountID)
                created = doc
                error = nil
                await NotificationService.checkBudgets(context: context)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    private func reset() {
        created = nil; clientName = ""; clientEmail = ""; clientPhone = ""; amountText = ""; itemDescription = ""
        remarks = ""; categoryID = nil; date = .now
    }
}

/// הגדרת חיבור ל-morning: סביבה + מפתחות API ב-Keychain + בדיקת חיבור
struct MorningSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MorningService.envKey) private var envRaw = MorningService.Environment.sandbox.rawValue
    @State private var clientId = ""
    @State private var secret = ""
    @State private var status: String?
    @State private var ok = false
    @State private var testing = false
    @State private var refresh = 0

    private var env: MorningService.Environment { MorningService.Environment(rawValue: envRaw) ?? .sandbox }

    var body: some View {
        Form {
            Section {
                Picker("סביבה", selection: $envRaw) {
                    ForEach(MorningService.Environment.allCases) { Text($0 == .sandbox ? "ניסיון" : "אמיתי").tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text(env.label).font(.caption).foregroundStyle(.secondary)
            } footer: { Text("מומלץ להתחיל בסביבת ניסיון. לכל סביבה יש מפתחות נפרדים.") }

            Section {
                LabeledContent("מצב", value: MorningService.isConfigured(env) ? "מוגדר ✓" : "לא מוגדר")
                    .id(refresh)
                TextField("Client ID", text: $clientId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
                SecureField("Client Secret", text: $secret)
                    .environment(\.layoutDirection, .leftToRight)
                Button("שמירה מאובטחת") {
                    let i = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !i.isEmpty, !s.isEmpty else { status = "יש למלא את שני השדות."; ok = false; return }
                    ok = KeychainStore.set(i, for: MorningService.idAccount(env)) && KeychainStore.set(s, for: MorningService.secretAccount(env))
                    status = ok ? "נשמר ב-Keychain." : "השמירה נכשלה."
                    clientId = ""; secret = ""; refresh += 1
                }
                .disabled(clientId.isEmpty || secret.isEmpty)
                Button {
                    testing = true
                    Task {
                        do { try await MorningService.testConnection(env); ok = true; status = "החיבור ל-morning תקין ✓" }
                        catch { ok = false; status = error.localizedDescription }
                        testing = false
                    }
                } label: { HStack { if testing { ProgressView() }; Text("בדיקת חיבור (לא מפיק מסמך)") } }
                .disabled(!MorningService.isConfigured(env) || testing)
                if let status { Text(status).font(.footnote).foregroundStyle(ok ? Theme.income : Theme.expense) }
                if MorningService.isConfigured(env) {
                    Button("מחיקת המפתחות של הסביבה הזו", role: .destructive) {
                        KeychainStore.delete(MorningService.idAccount(env)); KeychainStore.delete(MorningService.secretAccount(env))
                        status = "המפתחות נמחקו."; ok = false; refresh += 1
                    }
                }
            } header: { Text("מפתחות API (\(env == .sandbox ? "ניסיון" : "אמיתי"))") }
              footer: { Text("ב-morning: הגדרות ← כלים למפתחים ← API ← יצירת מפתח. מעתיקים את ה-ID וה-Secret ומדביקים כאן. המפתחות נשמרים רק ב-Keychain של האייפון ונשלחים רק ל-morning.") }

            Section {
                Link(destination: URL(string: "https://app.greeninvoice.co.il/settings/developers/api")!) {
                    Label("פתיחת עמוד המפתחות ב-morning", systemImage: "arrow.up.right.square")
                }
            }
        }
        .navigationTitle("חיבור ל-morning")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("סגירה") { dismiss() } } }
    }
}
