import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var entries: [Entry]
    @State private var editing: Account?
    @State private var creating = false
    @State private var reconciling: Account?

    var body: some View {
        let snaps = entries.map(\.snapshot)
        List {
            if accounts.isEmpty {
                EmptyStateView(symbol: "building.columns", title: "אין חשבונות", message: "הוסף חשבון בנק, חשבון עסקי, מזומן או כרטיס אשראי.",
                               actionTitle: "הוספת חשבון") { creating = true }
                    .listRowBackground(Color.clear)
            }
            ForEach(accounts) { a in
                let bal = BalanceEngine.balance(of: a.snapshot, entries: snaps)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(a.name, systemImage: a.kind.symbol).font(.headline)
                        Spacer()
                        MoneyText(money: bal, font: .headline, colored: bal.isNegative)
                    }
                    HStack {
                        Text("\(a.kind.label) · \(a.scope.label)")
                        if let d = a.billingDay, a.kind == .creditCard { Text("· חיוב ב-\(d) לחודש") }
                        if a.isArchived { Text("· בארכיון") }
                    }.font(.caption).foregroundStyle(.secondary)
                    Text("יתרה ידועה עודכנה: \(Fmt.dateTime(a.balanceDate))").font(.caption2).foregroundStyle(.tertiary)
                    HStack {
                        Button("עדכון יתרה מול הבנק") { reconciling = a }.buttonStyle(.bordered).font(.caption)
                        Button("עריכה") { editing = a }.buttonStyle(.bordered).font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("חשבונות")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") } } }
        .sheet(item: $editing) { a in NavigationStack { AccountEditorView(account: a) } }
        .sheet(isPresented: $creating) { NavigationStack { AccountEditorView(account: nil) } }
        .sheet(item: $reconciling) { a in
            AmountPromptView(title: "היתרה בפועל ב\(a.name)", confirmTitle: "עדכון") { m, _ in
                // בכרטיס אשראי מזינים את החוב כמספר חיובי — נשמר כשלילי
                try LedgerService(context: context).reconcile(a, actualBalance: a.kind == .creditCard ? -m : m)
            }
        }
    }
}

struct AccountEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allAccounts: [Account]
    let account: Account?
    @State private var name = ""
    @State private var kind: AccountKind = .bank
    @State private var scope: Scope = .personal
    @State private var balanceText = ""
    @State private var negative = false
    @State private var billingDay = 10
    @State private var includeInTotals = true
    @State private var archived = false
    @State private var isDefaultApplePay = false
    @State private var showDelete = false
    @State private var error: String?

    var body: some View {
        Form {
            if let error { ErrorBanner(message: error) }
            Section {
                TextField("שם (למשל: פועלים אישי, ישראכרט)", text: $name)
                Picker("סוג", selection: $kind) { ForEach(AccountKind.allCases) { Text($0.label).tag($0) } }
                ScopePicker(selection: $scope, personalTitle: "אישי", businessTitle: "עסקי")
            }
            if account == nil {
                Section {
                    AmountField(text: $balanceText)
                    Toggle(kind == .creditCard ? "יש חוב פתוח בכרטיס" : "היתרה במינוס", isOn: $negative)
                } header: { Text(kind == .creditCard ? "חוב נוכחי בכרטיס" : "יתרה נוכחית") }
                  footer: { Text("היתרה נכונה לרגע השמירה. תנועות מאושרות מכאן והלאה יעדכנו אותה. אפשר לעדכן מול הבנק בכל זמן.") }
            }
            if kind == .creditCard {
                Section {
                    Picker("יום חיוב בחודש", selection: $billingDay) { ForEach(1...31, id: \.self) { Text("\($0)").tag($0) } }
                    Toggle("כרטיס ברירת המחדל ל-Apple Pay", isOn: $isDefaultApplePay)
                } footer: { Text("רכישות בכרטיס נרשמות כהוצאות. החיוב החודשי מהבנק נרשם כ'סילוק כרטיס' — לא כהוצאה נוספת.") }
            }
            Section {
                Toggle("לכלול בסיכומים", isOn: $includeInTotals)
                if account != nil { Toggle("בארכיון", isOn: $archived) }
                if account != nil { Button("מחיקת החשבון", role: .destructive) { showDelete = true } }
            }
        }
        .navigationTitle(account == nil ? "חשבון חדש" : "עריכת חשבון")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("שמירה", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .onAppear {
            guard let a = account, name.isEmpty else { return }
            name = a.name; kind = a.kind; scope = a.scope; billingDay = a.billingDay ?? 10
            includeInTotals = a.includeInTotals; archived = a.isArchived
            isDefaultApplePay = AppSettings.defaultApplePayAccountID == a.id
        }
        .confirmationDialog("למחוק את החשבון?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) {
                if let a = account { context.delete(a); try? context.save(); dismiss() }
            }
        } message: { Text("התנועות שמשויכות לחשבון יישארו אבל לא ישויכו לשום חשבון. כדי לשמור היסטוריה עדיף להעביר לארכיון.") }
    }

    private func save() {
        let a = account ?? Account(name: name, kind: kind, scope: scope, sortOrder: allAccounts.count)
        a.name = name.trimmingCharacters(in: .whitespaces); a.kind = kind; a.scope = scope
        a.billingDay = kind == .creditCard ? billingDay : nil
        a.includeInTotals = includeInTotals; a.isArchived = archived
        if account == nil {
            let m = AmountParser.parse(balanceText)?.absolute ?? .zero
            a.knownBalance = negative ? -m : m
            a.balanceDate = .now
            context.insert(a)
        }
        if kind == .creditCard && isDefaultApplePay {
            UserDefaults.standard.set(a.id.uuidString, forKey: AppSettings.Key.defaultApplePayAccount)
        } else if AppSettings.defaultApplePayAccountID == a.id {
            UserDefaults.standard.removeObject(forKey: AppSettings.Key.defaultApplePayAccount)
        }
        do { try context.save(); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @State private var scope: Scope = .personal
    @State private var isIncome = false
    @State private var newName = ""
    @State private var parentForNew: UUID?

    var body: some View {
        let list = categories.filter { $0.scope == scope && $0.isIncome == isIncome && $0.parentID == nil }
        List {
            Section {
                ScopePicker(selection: $scope, personalTitle: "אישי", businessTitle: "עסקי")
                Picker("", selection: $isIncome) { Text("הוצאות").tag(false); Text("הכנסות").tag(true) }.pickerStyle(.segmented)
            }
            Section("הוספה") {
                TextField("שם קטגוריה חדשה", text: $newName)
                Picker("תחת קטגוריה (תת-קטגוריה)", selection: $parentForNew) {
                    Text("קטגוריה ראשית").tag(UUID?.none)
                    ForEach(list) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("הוספה") {
                    let c = Category(name: newName.trimmingCharacters(in: .whitespaces), scope: scope, isIncome: isIncome,
                                     parentID: parentForNew, sortOrder: categories.count)
                    context.insert(c); try? context.save(); newName = ""
                }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section {
                ForEach(list) { c in
                    VStack(alignment: .leading) {
                        HStack {
                            Label(c.name, systemImage: c.symbol)
                            Spacer()
                            if !c.isIncome {
                                Toggle("חיוני", isOn: Binding(get: { c.isEssential }, set: { c.isEssential = $0; try? context.save() }))
                                    .labelsHidden()
                                Text(c.isEssential ? "חיוני" : "לא חיוני").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        let subs = categories.filter { $0.parentID == c.id }
                        if !subs.isEmpty {
                            Text(subs.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .opacity(c.isArchived ? 0.4 : 1)
                    .swipeActions {
                        Button(c.isArchived ? "שחזור" : "הסתרה") { c.isArchived.toggle(); try? context.save() }.tint(.gray)
                    }
                }
            } footer: { Text("קטגוריות מוסתרות ולא נמחקות, כדי לא לפגוע בתנועות קיימות. 'לא חיוני' משמש את יועץ החיסכון.") }
        }
        .navigationTitle("קטגוריות")
    }
}
