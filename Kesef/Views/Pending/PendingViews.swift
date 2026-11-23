import SwiftUI
import SwiftData

/// תיבת העסקאות הממתינות — עובדת גם אם ההתראה לא הגיעה.
struct PendingInboxView: View {
    @Environment(AppRouter.self) private var router
    @Query(filter: #Predicate<Entry> { $0.statusRaw == "pendingReview" }, sort: \Entry.date, order: .reverse)
    private var pending: [Entry]
    @Query private var categories: [Category]
    @Query private var accounts: [Account]
    @State private var reviewing: Entry?
    @AppStorage(AppSettings.Key.lastApplePayIntentAt) private var lastIntent: Double = 0

    var body: some View {
        let lookup = NameLookup(categories: categories, accounts: accounts)
        List {
            if pending.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "אין עסקאות ממתינות",
                               message: lastIntent == 0
                                ? "רכישות Apple Pay יופיעו כאן אחרי שתגדיר את האוטומציה בקיצורים (הגדרות ← אוטומציית Apple Pay)."
                                : "כל הרכישות אושרו. רכישת Apple Pay אחרונה נקלטה ב-\(Fmt.dateTime(Date(timeIntervalSinceReferenceDate: lastIntent))).")
                    .listRowBackground(Color.clear)
            }
            ForEach(pending) { e in
                Button { reviewing = e } label: {
                    HStack(spacing: 12) {
                        Image(systemName: e.source == .applePayShortcut ? "applelogo" : "repeat")
                            .frame(width: 36, height: 36)
                            .background(Color(.tertiarySystemFill), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title.isEmpty ? "בית עסק חסר" : e.title).lineLimit(1)
                            Text("\(Fmt.dateTime(e.createdAt)) · \(e.source.label)")
                                .font(.caption).foregroundStyle(.secondary)
                            if e.possibleDuplicateOfID != nil {
                                Label("ייתכן שזו כפילות", systemImage: "doc.on.doc").font(.caption2).foregroundStyle(Theme.warning)
                            }
                            if e.amount.isZero || e.title.isEmpty {
                                Label("חסרים פרטים", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(Theme.expense)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            MoneyText(money: e.amount, font: .body.weight(.semibold))
                            Text(lookup.category(e.categoryID) == "ללא קטגוריה" ? e.scope.label : lookup.category(e.categoryID))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("ממתינות לאישור")
        .sheet(item: $reviewing) { e in PendingReviewView(entry: e) }
        .onChange(of: router.reviewEntryID) { _, id in openFromRouter(id) }
        .onAppear { openFromRouter(router.reviewEntryID) }
    }

    private func openFromRouter(_ id: UUID?) {
        guard let id else { return }
        if let e = pending.first(where: { $0.id == id }) { reviewing = e }
        router.reviewEntryID = nil
    }
}

/// מסך "זוהתה רכישה חדשה": אישית מסומנת מראש, אפשר להחליף לעסקית, לפצל, לתקן סכום, לאשר או לדחות.
struct PendingReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [Category]
    @Query private var allEntries: [Entry]
    let entry: Entry

    @State private var scope: Scope = .personal
    @State private var categoryID: UUID?
    @State private var amountText = ""
    @State private var title = ""
    @State private var note = ""
    @State private var accountID: UUID?
    @State private var editing = false
    @State private var split = false
    @State private var businessText = ""
    @State private var personalCategoryID: UUID?
    @State private var businessCategoryID: UUID?
    @State private var rememberCard = true
    @State private var error: String?
    @State private var showReject = false
    @State private var loaded = false

    private var amount: Money? { AmountParser.parse(amountText)?.absolute }
    private var businessPart: Money? { AmountParser.parse(businessText)?.absolute }
    private var needsDetails: Bool { entry.amount.isZero || entry.title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if let error { ErrorBanner(message: error) }
                    if let dupID = entry.possibleDuplicateOfID { duplicateWarning(dupID) }
                    if editing || needsDetails { detailsEditor } else { detailsSummary }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("סוג ההוצאה").font(.headline)
                        ScopePicker(selection: $scope)
                            .disabled(split)
                            .opacity(split ? 0.4 : 1)
                    }.card()

                    if split { splitEditor } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("קטגוריה").font(.headline)
                            CategoryChips(selection: $categoryID, scope: scope, isIncome: false)
                        }.card()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("פיצול לאישי ועסקי", isOn: $split.animation())
                        TextField("הערה", text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }.card()

                    Color.clear.frame(height: 120)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle("אישור רכישה")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("אחר כך") { dismiss() } } }
            .onAppear(perform: load)
            .onChange(of: scope) { _, newScope in
                if let c = categories.first(where: { $0.id == categoryID }), c.scope != newScope { categoryID = nil }
            }
            .confirmationDialog("לדחות את הרכישה?", isPresented: $showReject, titleVisibility: .visible) {
                Button("דחה — לא לשמור כהוצאה", role: .destructive) { reject() }
            } message: { Text("העסקה תסומן כ'בוטלה' ולא תיכלל בחישובים. אם האוטומציה תרוץ שוב על אותה רכישה, היא לא תיווצר מחדש.") }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Label("זוהתה רכישה חדשה", systemImage: entry.source == .applePayShortcut ? "applelogo" : "repeat")
                .font(.headline).foregroundStyle(.secondary)
            Text(title.isEmpty ? "בית עסק חסר" : title).font(.title2.bold()).multilineTextAlignment(.center)
            MoneyText(money: amount ?? .zero, font: .system(size: 48, weight: .bold, design: .rounded))
            Text(Fmt.dateTime(entry.date)).font(.subheadline).foregroundStyle(.secondary)
            if let card = entry.cardLabel {
                Label(card, systemImage: "creditcard").font(.subheadline).foregroundStyle(.secondary)
            }
            if entry.source == .applePayShortcut {
                Text("מקור: Apple Pay / Shortcuts").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func duplicateWarning(_ dupID: UUID) -> some View {
        let other = allEntries.first { $0.id == dupID }
        return VStack(alignment: .leading, spacing: 8) {
            Label("ייתכן שזו כפילות", systemImage: "doc.on.doc.fill").font(.headline).foregroundStyle(Theme.warning)
            if let other {
                Text("רכישה דומה: \(other.title) · \(MoneyFormat.string(other.amount)) · \(Fmt.dateTime(other.createdAt)) (\(other.status.label(for: other.kind)))")
                    .font(.subheadline)
            }
            HStack {
                Button("זו רכישה נפרדת") {
                    do { try PendingTransactionService(context: context).markNotDuplicate(entry) } catch { self.error = error.localizedDescription }
                }.buttonStyle(.bordered)
                Button("זו כפילות — דחה", role: .destructive) { reject() }.buttonStyle(.bordered)
            }
        }.card()
    }

    private var detailsSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("חשבון / כרטיס", value: accounts.first { $0.id == accountID }?.name ?? "לא משויך")
            Button("עריכת פרטים") { withAnimation { editing = true } }
        }.card()
    }

    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    private var detailsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if needsDetails {
                Label("iOS לא העביר את כל הפרטים — השלם אותם.", systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(Theme.expense)
            }
            Text("סכום").font(.caption).foregroundStyle(.secondary)
            AmountField(text: $amountText)
            TextField("שם בית העסק", text: $title).textFieldStyle(.roundedBorder)
            AccountPicker(title: "שולם מ", selection: $accountID)
            if entry.cardLabel != nil && accountID != nil {
                Toggle("לשייך את הכרטיס הזה לחשבון תמיד", isOn: $rememberCard).font(.subheadline)
            }
        }.card()
    }

    private var splitEditor: some View {
        let total = amount ?? .zero
        let business = businessPart ?? .zero
        let personal = total - business
        return VStack(alignment: .leading, spacing: 12) {
            Text("פיצול הסכום").font(.headline)
            HStack {
                Text("חלק עסקי")
                Spacer()
                TextField("0", text: $businessText).keyboardType(.decimalPad).multilineTextAlignment(.leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(width: 120).textFieldStyle(.roundedBorder)
                Text("₪")
            }
            HStack {
                Text("חלק אישי")
                Spacer()
                MoneyText(money: personal, font: .body.weight(.semibold), colored: personal.isNegative)
            }
            HStack(spacing: 8) {
                ForEach([2_500, 5_000, 7_500], id: \.self) { bp in
                    Button("\(bp / 100)% עסקי") { businessText = MoneyFormat.editString(total.multiplied(byBasisPoints: bp)) }
                        .buttonStyle(.bordered).font(.caption)
                }
            }
            Text("סכום שני החלקים שווה תמיד לסכום המקורי.").font(.caption).foregroundStyle(.secondary)
            Text("קטגוריה לחלק האישי").font(.subheadline.weight(.semibold))
            CategoryChips(selection: $personalCategoryID, scope: .personal, isIncome: false)
            Text("קטגוריה לחלק העסקי").font(.subheadline.weight(.semibold))
            CategoryChips(selection: $businessCategoryID, scope: .business, isIncome: false)
        }.card()
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            Button(action: confirm) {
                Text("אשר ושמור").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(amount == nil || amount?.isZero == true || title.trimmingCharacters(in: .whitespaces).isEmpty)
            HStack {
                Button(editing ? "סיום עריכה" : "עריכה") { withAnimation { editing.toggle() } }
                    .frame(maxWidth: .infinity)
                Button("דחה", role: .destructive) { showReject = true }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        // ברירת מחדל: הסיווג שנשמר בעסקה (אישית כברירת מחדל מההגדרות)
        scope = entry.scope
        categoryID = entry.categoryID
        amountText = entry.amount.isZero ? "" : MoneyFormat.editString(entry.amount)
        title = entry.title
        note = entry.note
        accountID = entry.accountID
    }

    private func confirm() {
        guard let amount else { error = "חסר סכום."; return }
        let req = PendingTransactionService.ConfirmRequest(
            amount: amount, title: title, scope: scope, categoryID: categoryID, accountID: accountID, note: note,
            businessSplitAmount: split ? (businessPart ?? .zero) : nil,
            businessCategoryID: businessCategoryID, personalCategoryID: personalCategoryID,
            rememberCardForAccount: rememberCard)
        do {
            try PendingTransactionService(context: context).confirm(entry, with: req)
            NotificationService.removePendingNotification(entryID: entry.id)
            Task { await NotificationService.updateBadge(context: context); await NotificationService.checkBudgets(context: context) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reject() {
        do {
            try PendingTransactionService(context: context).reject(entry)
            NotificationService.removePendingNotification(entryID: entry.id)
            Task { await NotificationService.updateBadge(context: context) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
