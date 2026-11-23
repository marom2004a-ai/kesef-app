import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @Query private var categories: [Category]
    @Query private var accounts: [Account]

    enum KindFilter: String, CaseIterable, Identifiable {
        case all, income, expense, other
        var id: String { rawValue }
        var label: String {
            switch self { case .all: return "הכול"; case .income: return "הכנסות"; case .expense: return "הוצאות"; case .other: return "העברות" }
        }
    }

    @State private var month = FinanceCalendar.israel.startOfMonth(.now)
    @State private var kindFilter: KindFilter = .all
    @State private var scopeFilter: Scope?
    @State private var search = ""
    @State private var editing: Entry?
    @State private var toDelete: Entry?
    @State private var error: String?

    private let cal = FinanceCalendar.israel

    private var filtered: [Entry] {
        let range = cal.monthRange(month)
        let q = search.trimmingCharacters(in: .whitespaces)
        return entries.filter { e in
            guard range.contains(e.date) else { return false }
            switch kindFilter {
            case .all: break
            case .income: if !(e.kind == .income || e.kind == .refund) { return false }
            case .expense: if e.kind != .expense { return false }
            case .other: if e.kind.isProfitAndLoss { return false }
            }
            if let s = scopeFilter, e.scope != s { return false }
            if !q.isEmpty && !e.title.localizedCaseInsensitiveContains(q) && !e.note.localizedCaseInsensitiveContains(q) { return false }
            return true
        }
    }

    var body: some View {
        let lookup = NameLookup(categories: categories, accounts: accounts)
        let items = filtered
        let grouped = Dictionary(grouping: items) { cal.startOfDay($0.date) }.sorted { $0.key > $1.key }
        let summary = BalanceEngine.summary(entries: items.map(\.snapshot), in: cal.monthRange(month))

        List {
            Section {
                monthSwitcher
                Picker("סוג", selection: $kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    VStack(alignment: .leading) {
                        Text("הכנסות").font(.caption).foregroundStyle(.secondary)
                        MoneyText(money: summary.income, font: .headline).foregroundStyle(Theme.income)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("הוצאות נטו").font(.caption).foregroundStyle(.secondary)
                        MoneyText(money: summary.netExpenses, font: .headline)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("מאושר בלבד").font(.caption2).foregroundStyle(.secondary)
                        DataKindBadge(isForecast: false)
                    }
                }
            }
            if let error { Section { ErrorBanner(message: error) } }

            if items.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: "אין תנועות",
                               message: search.isEmpty ? "לא נרשמו תנועות בחודש הזה." : "לא נמצאו תנועות שמתאימות לחיפוש.",
                               actionTitle: "הוספת הוצאה") { router.showQuickAdd = .expense }
                    .listRowBackground(Color.clear)
            }

            ForEach(grouped, id: \.key) { day, dayEntries in
                Section(Fmt.dayMonth(day)) {
                    ForEach(dayEntries) { e in
                        Button { editing = e } label: { EntryRow(entry: e, lookup: lookup) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("מחיקה", role: .destructive) { toDelete = e }
                            }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "חיפוש לפי תיאור או הערה")
        .navigationTitle("תנועות")
        .kesefScreen()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("סיווג", selection: $scopeFilter) {
                        Text("אישי ועסקי").tag(Scope?.none)
                        ForEach(Scope.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    Divider()
                    Button("הכנסה חדשה") { router.showQuickAdd = .income }
                    Button("הוצאה חדשה") { router.showQuickAdd = .expense }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        .sheet(item: $editing) { e in NavigationStack { EntryEditorView(existing: e) } }
        .confirmationDialog("למחוק את התנועה?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("מחיקה לצמיתות", role: .destructive) {
                if let e = toDelete {
                    do { try LedgerService(context: context).delete(e); error = nil } catch { self.error = error.localizedDescription }
                }
                toDelete = nil
            }
        } message: { Text(toDelete.map { "\($0.title) · \(MoneyFormat.string($0.amount))" } ?? "") }
    }

    private var monthSwitcher: some View {
        HStack {
            Button { month = cal.addMonths(-1, to: month) } label: { Image(systemName: "chevron.right") }
            Spacer()
            Text(Fmt.monthYear(month)).font(.headline)
            Spacer()
            Button { month = cal.addMonths(1, to: month) } label: { Image(systemName: "chevron.left") }
        }
        .buttonStyle(.borderless)
    }
}

struct EntryRow: View {
    let entry: Entry
    let lookup: NameLookup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: lookup.symbol(entry.categoryID))
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "ללא תיאור" : entry.title).font(.body).lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.kind.isProfitAndLoss ? lookup.category(entry.categoryID) : entry.kind.label)
                    Text("·")
                    Text(entry.scope.label)
                    if entry.status != .confirmed {
                        Text("·")
                        Text(entry.status.label(for: entry.kind)).foregroundStyle(entry.status == .cancelled ? Color.secondary : Theme.forecast)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(money: signed, font: .body.weight(.semibold), colored: entry.status == .confirmed, showPlus: signed.isPositive)
                .strikethrough(entry.status == .cancelled)
                .opacity(entry.status == .cancelled ? 0.5 : 1)
        }
        .contentShape(Rectangle())
    }

    private var signed: Money {
        switch entry.kind {
        case .income, .refund: return entry.amount
        case .expense, .partnerPayout, .taxPayment: return -entry.amount
        default: return entry.amount
        }
    }
}
