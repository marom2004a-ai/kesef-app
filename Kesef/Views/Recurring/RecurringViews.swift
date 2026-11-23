import SwiftUI
import SwiftData

struct RecurringListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringRule.dayOfMonth) private var rules: [RecurringRule]
    @Query private var categories: [Category]
    @Query private var accounts: [Account]
    @State private var editing: RecurringRule?
    @State private var creating = false
    @State private var toDelete: RecurringRule?

    var body: some View {
        let lookup = NameLookup(categories: categories, accounts: accounts)
        let active = rules.filter { !$0.isPaused }
        let monthlyOut = active.filter { $0.kind == .expense }.map { $0.snapshot.monthlyEquivalent }.sum()
        let monthlyIn = active.filter { $0.kind == .income }.map { $0.snapshot.monthlyEquivalent }.sum()
        List {
            Section {
                LabeledContent("חיובים קבועים בחודש") { MoneyText(money: monthlyOut, font: .headline) }
                if !monthlyIn.isZero { LabeledContent("הכנסות קבועות בחודש") { MoneyText(money: monthlyIn, font: .headline) } }
                Text("חיובים שאינם חודשיים מחושבים לפי שווי חודשי. חיוב אשראי חודשי לא נרשם כאן אם הרכישות עצמן כבר נרשמות — הוא מחושב אוטומטית לפי יום החיוב של הכרטיס.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if rules.isEmpty {
                EmptyStateView(symbol: "repeat", title: "אין חיובים קבועים",
                               message: "הוסף שכירות, רכב, הלוואות, ביטוחים, מנויים וספקים כדי לקבל תחזית ותזכורות.",
                               actionTitle: "הוספת חיוב קבוע") { creating = true }
                    .listRowBackground(Color.clear)
            }
            ForEach([Scope.personal, Scope.business]) { scope in
                let items = rules.filter { $0.scope == scope }
                if !items.isEmpty {
                    Section(scope == .personal ? "אישי" : "עסקי") {
                        ForEach(items) { r in
                            Button { editing = r } label: { row(r, lookup) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("מחיקה", role: .destructive) { toDelete = r }
                                    Button(r.isPaused ? "חידוש" : "השהיה") { r.isPaused.toggle(); try? context.save() }.tint(.orange)
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("חיובים קבועים")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") } } }
        .sheet(item: $editing) { r in NavigationStack { RecurringEditorView(rule: r) } }
        .sheet(isPresented: $creating) { NavigationStack { RecurringEditorView(rule: nil) } }
        .confirmationDialog("למחוק את החיוב הקבוע?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) {
                if let r = toDelete { context.delete(r); try? context.save() }
                toDelete = nil
            }
        } message: { Text("תנועות שכבר נרשמו מהחיוב יישארו. תחזיות ותזכורות עתידיות יוסרו.") }
    }

    private func row(_ r: RecurringRule, _ lookup: NameLookup) -> some View {
        let next = RecurrenceEngine.nextOccurrence(of: r.snapshot, onOrAfter: .now)
        return HStack(spacing: 12) {
            Image(systemName: lookup.symbol(r.categoryID)).frame(width: 34, height: 34).background(Color(.tertiarySystemFill), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).lineLimit(1)
                Group {
                    if r.isPaused { Text("מושהה") }
                    else if let next { Text("\(r.frequency.label) · הבא: \(Fmt.dayMonth(next))") }
                    else { Text("הסתיים") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                MoneyText(money: r.kind == .income ? r.amount : -r.amount, font: .body.weight(.semibold), colored: true)
                if r.isVariableAmount { Text("משוער").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .opacity(r.isPaused ? 0.5 : 1)
        .contentShape(Rectangle())
    }
}

struct RecurringEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [Category]
    let rule: RecurringRule?

    @State private var title = ""
    @State private var kind: EntryKind = .expense
    @State private var amountText = ""
    @State private var isVariable = false
    @State private var frequency: Frequency = .monthly
    @State private var dayOfMonth = 1
    @State private var startDate = Date.now
    @State private var hasEnd = false
    @State private var endDate = FinanceCalendar.israel.addMonths(12, to: .now)
    @State private var scope: Scope = .personal
    @State private var categoryID: UUID?
    @State private var accountID: UUID?
    @State private var paymentMethod: PaymentMethod = .standingOrder
    @State private var remind = true
    @State private var remindDays = 1
    @State private var autoPending = true
    @State private var isPaused = false
    @State private var note = ""
    @State private var loaded = false

    private var amount: Money? { AmountParser.parse(amountText)?.absolute }

    var body: some View {
        Form {
            Section {
                Picker("סוג", selection: $kind) {
                    Text("הוצאה").tag(EntryKind.expense)
                    Text("הכנסה").tag(EntryKind.income)
                }.pickerStyle(.segmented)
                TextField("שם (שכירות, ביטוח רכב, מנוי…)", text: $title)
                AmountField(text: $amountText)
                Toggle("הסכום משתנה מחודש לחודש", isOn: $isVariable)
                if isVariable { Text("הזן סכום משוער. בכל חיוב תתבקש לאשר את הסכום בפועל.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("מועד") {
                Picker("תדירות", selection: $frequency) { ForEach(Frequency.allCases) { Text($0.label).tag($0) } }
                if frequency != .weekly {
                    Picker("יום חיוב בחודש", selection: $dayOfMonth) { ForEach(1...31, id: \.self) { Text("\($0)").tag($0) } }
                }
                DatePicker("החל מ", selection: $startDate, displayedComponents: .date)
                Toggle("יש תאריך סיום", isOn: $hasEnd)
                if hasEnd { DatePicker("תאריך סיום", selection: $endDate, displayedComponents: .date) }
                Toggle("מושהה", isOn: $isPaused)
            }
            Section("סיווג ותשלום") {
                ScopePicker(selection: $scope, personalTitle: "אישי", businessTitle: "עסקי")
                CategoryChips(selection: $categoryID, scope: scope, isIncome: kind == .income)
                AccountPicker(title: "חשבון תשלום", selection: $accountID)
                if kind == .expense {
                    Picker("אמצעי תשלום", selection: $paymentMethod) { ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) } }
                }
            }
            .onChange(of: scope) { _, s in
                if let c = categories.first(where: { $0.id == categoryID }), c.scope != s { categoryID = nil }
            }
            Section("תזכורות ורישום") {
                Toggle("תזכורת לפני החיוב", isOn: $remind)
                if remind { Stepper(remindDays == 0 ? "ביום החיוב" : "\(remindDays) ימים לפני", value: $remindDays, in: 0...14) }
                Toggle("ליצור תנועה ממתינה לאישור ביום החיוב", isOn: $autoPending)
                TextField("הערה", text: $note)
            }
        }
        .navigationTitle(rule == nil ? "חיוב קבוע חדש" : "עריכת חיוב קבוע")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("שמירה", action: save).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || amount?.isPositive != true)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let r = rule else { dayOfMonth = FinanceCalendar.israel.day(.now); return }
        title = r.title; kind = r.kind; amountText = MoneyFormat.editString(r.amount); isVariable = r.isVariableAmount
        frequency = r.frequency; dayOfMonth = r.dayOfMonth; startDate = r.startDate; hasEnd = r.endDate != nil
        endDate = r.endDate ?? endDate; scope = r.scope; categoryID = r.categoryID; accountID = r.accountID
        paymentMethod = r.paymentMethod ?? .standingOrder; remind = r.remindDaysBefore != nil; remindDays = r.remindDaysBefore ?? 1
        autoPending = r.autoCreatePending; isPaused = r.isPaused; note = r.note
    }

    private func save() {
        guard let amount else { return }
        let r = rule ?? RecurringRule(title: title, amount: amount, dayOfMonth: dayOfMonth)
        r.title = title.trimmingCharacters(in: .whitespaces); r.kind = kind; r.amount = amount; r.isVariableAmount = isVariable
        r.frequency = frequency
        r.dayOfMonth = frequency == .weekly ? FinanceCalendar.israel.day(startDate) : dayOfMonth
        r.startDate = startDate; r.endDate = hasEnd ? endDate : nil; r.scope = scope; r.categoryID = categoryID
        r.accountID = accountID; r.paymentMethod = kind == .expense ? paymentMethod : nil
        r.remindDaysBefore = remind ? remindDays : nil; r.autoCreatePending = autoPending; r.isPaused = isPaused; r.note = note
        if rule == nil { context.insert(r) }
        try? context.save()
        Task { await AppLifecycle.refresh() }
        dismiss()
    }
}
