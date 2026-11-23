import SwiftUI
import SwiftData

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query private var budgets: [Budget]
    @Query private var entries: [Entry]
    @Query private var categories: [Category]
    @State private var month = FinanceCalendar.israel.startOfMonth(.now)
    @State private var editing: Budget?
    @State private var creating = false

    private let cal = FinanceCalendar.israel

    var body: some View {
        let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let statuses = BudgetEngine.status(budgets: budgets.map(\.snapshot), entries: entries.map(\.snapshot), month: month,
                                           now: .now, alertBasisPoints: AppSettings.budgetAlertBasisPoints, calendar: cal)
        let totalLimit = statuses.map(\.limit).sum()
        let totalUsed = statuses.map(\.used).sum()
        List {
            Section {
                HStack {
                    Button { month = cal.addMonths(-1, to: month) } label: { Image(systemName: "chevron.right") }
                    Spacer(); Text(Fmt.monthYear(month)).font(.headline); Spacer()
                    Button { month = cal.addMonths(1, to: month) } label: { Image(systemName: "chevron.left") }
                }.buttonStyle(.borderless)
                if !statuses.isEmpty {
                    LabeledContent("סה״כ מתוכנן") { MoneyText(money: totalLimit) }
                    LabeledContent("נוצל") { MoneyText(money: totalUsed) }
                    LabeledContent("נותר") { MoneyText(money: totalLimit - totalUsed, colored: true) }
                }
            }
            if statuses.isEmpty {
                EmptyStateView(symbol: "chart.pie", title: "אין תקציבים",
                               message: "קבע תקרה חודשית לקטגוריות כמו מזון, מסעדות, רכב או פרסום עסקי, וקבל התראה כשמתקרבים אליה.",
                               actionTitle: "הוספת תקציב") { creating = true }
                    .listRowBackground(Color.clear)
            }
            ForEach(statuses) { st in
                let cat = names[st.categoryID]
                Button { editing = budgets.first { $0.id == st.budgetID } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(cat?.name ?? "קטגוריה שנמחקה", systemImage: cat?.symbol ?? "tag")
                            Spacer()
                            Text(st.level.label).font(.caption.weight(.semibold)).foregroundStyle(color(st.level))
                        }
                        ProgressView(value: Double(min(st.usedBasisPoints, 10_000)), total: 10_000)
                            .tint(color(st.level))
                        HStack {
                            Text("נוצלו \(MoneyFormat.string(st.used)) מתוך \(MoneyFormat.string(st.limit)) · \(Fmt.percent(st.usedBasisPoints))")
                            Spacer()
                            Text(st.remaining.isNegative ? "חריגה \(MoneyFormat.string(st.remaining.absolute))" : "נותרו \(MoneyFormat.string(st.remaining))")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let p = st.projected, p > st.limit {
                            Text("בקצב הנוכחי: כ-\(MoneyFormat.string(p)) עד סוף החודש (הערכה)").font(.caption2).foregroundStyle(Theme.warning)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("מחיקה", role: .destructive) {
                        if let b = budgets.first(where: { $0.id == st.budgetID }) { context.delete(b); try? context.save() }
                    }
                }
            }
        }
        .navigationTitle("תקציבים")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") } } }
        .sheet(item: $editing) { b in NavigationStack { BudgetEditorView(budget: b) } }
        .sheet(isPresented: $creating) { NavigationStack { BudgetEditorView(budget: nil) } }
    }

    private func color(_ l: BudgetLevel) -> Color {
        switch l { case .ok: return Theme.income; case .projectedOver: return Theme.warning; case .warning: return Theme.warning; case .over: return Theme.expense }
    }
}

struct BudgetEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var budgets: [Budget]
    let budget: Budget?
    @State private var scope: Scope = .personal
    @State private var categoryID: UUID?
    @State private var amountText = ""
    @State private var error: String?
    @AppStorage(AppSettings.Key.budgetAlertBP) private var alertBP = 8000

    var body: some View {
        Form {
            if let error { ErrorBanner(message: error) }
            Section("תקרה חודשית") { AmountField(text: $amountText, autoFocus: budget == nil) }
            Section("קטגוריה") {
                ScopePicker(selection: $scope, personalTitle: "אישי", businessTitle: "עסקי")
                CategoryChips(selection: $categoryID, scope: scope, isIncome: false)
            }
            Section("התראה") {
                Stepper("התראה ב-\(alertBP / 100)% ניצול", value: $alertBP, in: 5000...10000, step: 500)
                Text("ההגדרה חלה על כל התקציבים.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(budget == nil ? "תקציב חדש" : "עריכת תקציב")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("שמירה", action: save).disabled(categoryID == nil) }
        }
        .onAppear {
            if let b = budget, amountText.isEmpty { amountText = MoneyFormat.editString(b.limit); categoryID = b.categoryID }
        }
    }

    private func save() {
        guard let m = AmountParser.parse(amountText)?.absolute, m.isPositive, let cat = categoryID else { error = "הזן סכום ובחר קטגוריה."; return }
        if budgets.contains(where: { $0.categoryID == cat && $0.id != budget?.id }) { error = "כבר קיים תקציב לקטגוריה הזו."; return }
        let b = budget ?? Budget(categoryID: cat, limit: m)
        b.categoryID = cat; b.limit = m
        if budget == nil { context.insert(b) }
        do { try context.save(); dismiss() } catch { self.error = error.localizedDescription }
    }
}
