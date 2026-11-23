import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Query private var entries: [Entry]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rules: [RecurringRule]
    @State private var showAddAccount = false
    @AppStorage(AppSettings.Key.reserveMinor) private var reserveMinor = 0
    @AppStorage(AppSettings.Key.monthlySavingsMinor) private var savingsMinor = 0
    @AppStorage(AppSettings.Key.partnerShareBP) private var partnerBP = 0

    private var dashboard: DashboardSnapshot {
        DashboardEngine.build(now: .now, accounts: accounts.map(\.snapshot), entries: entries.map(\.snapshot),
                              recurring: rules.map(\.snapshot), partner: partnerBP > 0 ? AppSettings.partner : nil,
                              monthlySavingsTarget: Money(minorUnits: Int64(savingsMinor)), reserve: Money(minorUnits: Int64(reserveMinor)))
    }

    var body: some View {
        let d = dashboard
        ScrollView {
            VStack(spacing: 14) {
                if accounts.filter({ !$0.isArchived }).isEmpty {
                    EmptyStateView(symbol: "building.columns", title: "בוא נתחיל",
                                   message: "הוסף חשבון בנק, מזומן או כרטיס אשראי עם היתרה הנוכחית שלו. אחר כך אפשר להוסיף הכנסות והוצאות.",
                                   actionTitle: "הוספת חשבון ראשון") { showAddAccount = true }
                        .card()
                } else {
                    balanceCard(d)
                }
                if !d.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(d.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Theme.warning)
                        }
                    }.card()
                }
                if d.pendingReviewCount > 0 { pendingCard(d.pendingReviewCount) }
                monthGrid(d)
                forecastCard(d)
                if let owed = d.partnerOwed { partnerCard(owed) }
                upcomingCard
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("הכסף שלי")
        .safeAreaInset(edge: .bottom, spacing: 0) { quickAddBar }
        .sheet(isPresented: $showAddAccount) { NavigationStack { AccountEditorView(account: nil) } }
    }

    // MARK: חלקים

    private func balanceCard(_ d: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("יתרה נוכחית").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                DataKindBadge(isForecast: false)
            }
            MoneyText(money: d.currentBalance, font: .system(size: 42, weight: .bold, design: .rounded), colored: d.currentBalance.isNegative)
            if let last = d.lastBalanceUpdate {
                Text("לפי היתרות שעודכנו לאחרונה ב-\(Fmt.dateTime(last)) ותנועות מאושרות מאז")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if !d.creditCardDebt.isZero {
                    VStack(alignment: .leading) {
                        Text("חוב באשראי").font(.caption).foregroundStyle(.secondary)
                        MoneyText(money: d.creditCardDebt, font: .subheadline.weight(.semibold), colored: true)
                    }
                }
                if !d.savings.isZero {
                    VStack(alignment: .leading) {
                        Text("בחיסכון").font(.caption).foregroundStyle(.secondary)
                        MoneyText(money: d.savings, font: .subheadline.weight(.semibold))
                    }
                }
            }
        }
        .card()
    }

    private func pendingCard(_ count: Int) -> some View {
        Button { router.selectedTab = .pending } label: {
            HStack {
                Image(systemName: "tray.full.fill").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading) {
                    Text(count == 1 ? "עסקה אחת ממתינה לאישור" : "\(count) עסקאות ממתינות לאישור").font(.headline)
                    Text("רכישות Apple Pay וחיובים קבועים שעוד לא אישרת").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.left").foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private func monthGrid(_ d: DashboardSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            tile("הכנסות החודש", d.monthIncome, symbol: "arrow.down.circle.fill", color: Theme.income, forecast: false)
            tile("הוצאות החודש", d.monthExpenses, symbol: "arrow.up.circle.fill", color: Theme.expense, forecast: false)
            tile("הכנסות צפויות", d.expectedIncome, symbol: "clock.arrow.circlepath", color: Theme.forecast, forecast: true)
            tile("הוצאות עתידיות", d.upcomingExpenses, symbol: "calendar.badge.clock", color: Theme.forecast, forecast: true)
        }
    }

    private func tile(_ title: String, _ money: Money, symbol: String, color: Color, forecast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundStyle(color)
                Spacer()
                DataKindBadge(isForecast: forecast)
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
            MoneyText(money: money, font: .title3.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func forecastCard(_ d: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("סכום פנוי לשימוש").font(.headline)
                Spacer()
                DataKindBadge(isForecast: true)
            }
            MoneyText(money: d.safeToSpend, font: .system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
            Text("היתרה הנמוכה ביותר עד סוף החודש בתרחיש שמרני — אחרי חיובים, הוצאות מתוכננות, חלק השותף ויעד החיסכון — פחות כרית הביטחון.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text("תחזית לסוף החודש").font(.caption).foregroundStyle(.secondary)
                    MoneyText(money: d.forecastEndOfMonth, font: .headline, colored: true)
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("בתרחיש שמרני").font(.caption).foregroundStyle(.secondary)
                    MoneyText(money: d.forecastEndOfMonthConservative, font: .headline, colored: true)
                }
            }
            Button("לתחזית המלאה") { router.selectedTab = .forecast }.font(.subheadline)
        }
        .card()
    }

    private func partnerCard(_ owed: Money) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("חלק השותף החודש (\(AppSettings.partner.name))").font(.subheadline).foregroundStyle(.secondary)
            MoneyText(money: owed, font: .title3.weight(.semibold))
            Text(owed.isNegative ? "שולם לשותף יותר מחלקו החודש." : "כסף ששייך לשותף — לא נכלל בסכום הפנוי.")
                .font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    private var upcomingCard: some View {
        let cal = FinanceCalendar.israel
        let now = Date.now
        let end = cal.addDays(14, to: now)
        let snapshots = entries.map(\.snapshot)
        var items: [(Date, String, Money, Bool)] = []
        for r in rules where !r.isPaused {
            for o in RecurrenceEngine.occurrences(of: r.snapshot, from: now, to: end, calendar: cal)
            where !RecurrenceEngine.isRecorded(rule: r.id, occurrence: o, entries: snapshots, calendar: cal) {
                items.append((o, r.title, r.amount, r.kind == .income))
            }
        }
        for e in entries where e.status == .planned && e.date >= cal.startOfDay(now) && e.date < end {
            items.append((e.date, e.title, e.amount, e.kind == .income))
        }
        items.sort { $0.0 < $1.0 }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "ב-14 הימים הקרובים", trailing: "תחזית")
            if items.isEmpty {
                Text("אין חיובים או הכנסות מתוכננים.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(Fmt.dayMonth(item.0)).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                        Text(item.1).lineLimit(1)
                        Spacer()
                        MoneyText(money: item.3 ? item.2 : -item.2, font: .subheadline, colored: true, showPlus: item.3)
                    }
                }
            }
        }.card()
    }

    /// פס הוספה מהירה קבוע מעל סרגל הלשוניות — לא מכסה תוכן (safeAreaInset)
    private var quickAddBar: some View {
        HStack(spacing: 10) {
            Button { router.showQuickAdd = .expense } label: {
                Text("+ הוצאה")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)

            Button { router.showQuickAdd = .income } label: {
                Text("+ הכנסה")
                    .font(.headline)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(minHeight: 50)
            }
            .buttonStyle(.bordered)
            .tint(Theme.income)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
