import SwiftUI
import SwiftData

/// מסך הבית: מספר אחד גדול (רווח העסק / כמה נשאר לי), הכלב המלווה, סדרה ואתגר, והוספה מהירה.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Query private var entries: [Entry]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rules: [RecurringRule]
    @Query private var categories: [Category]
    @AppStorage(AppSettings.Key.vatRegistered) private var vatRegistered = true
    @AppStorage(AppSettings.Key.reserveMinor) private var reserveMinor = 0
    @AppStorage(AppSettings.Key.monthlySavingsMinor) private var savingsMinor = 0
    @AppStorage(AppSettings.Key.partnerShareBP) private var partnerBP = 0
    @AppStorage(AppSettings.Key.partnerName) private var partnerName = "מרום"
    @AppStorage(AppSettings.Key.vatPeriodMonths) private var periodMonths = 2
    @State private var showAddAccount = false
    @State private var showReceiptCapture = false

    /// מרחב תצוגה: עסקי / אישי (ערך ישן "all" נפתח כעסקי)
    @AppStorage("homeSpace") private var spaceRaw = Scope.business.rawValue
    private var space: Scope { Scope(rawValue: spaceRaw) ?? .business }
    private var isBusiness: Bool { space == .business }

    private let cal = FinanceCalendar.israel

    // MARK: נתונים

    private struct Model {
        var dashboard: DashboardSnapshot
        var series: [MonthPoint]
        var headline: Money
        var changeBP: Int?
        var isRecord: Bool
        var partnerShare: Money?
        var missingReceipts: Int
        var periodExpenseCount: Int
        var streak: Int
        var savedThisMonth: Money
        var monthIncome: Money
        var monthExpenses: Money
        var companion: CompanionMessage
    }

    private func buildModel() -> Model {
        let accs = accounts.map(\.snapshot)
        let all = entries.map(\.snapshot)
        let ids = Set(accs.filter { $0.scope == space }.map(\.id))
        let scopedEntries = all.filter { $0.scope == space || $0.accountID.map { ids.contains($0) } == true || $0.toAccountID.map { ids.contains($0) } == true }
        let deductible = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.vatDeductibleBP) })
        let vat = AppSettings.vat
        let d = DashboardEngine.build(now: .now, accounts: accs.filter { $0.scope == space }, entries: scopedEntries,
                                      recurring: rules.map(\.snapshot).filter { $0.scope == space },
                                      partner: (partnerBP > 0 && isBusiness) ? AppSettings.partner : nil,
                                      monthlySavingsTarget: Money(minorUnits: Int64(savingsMinor)), reserve: Money(minorUnits: Int64(reserveMinor)),
                                      vat: (vatRegistered && isBusiness) ? vat : nil, vatDeductibleBP: deductible)
        let series = isBusiness
            ? MonthlySeries.businessProfit(entries: all, months: 6, now: .now, vat: vat, deductibleBP: deductible, calendar: cal)
            : MonthlySeries.personalNet(entries: all, months: 6, now: .now, calendar: cal)
        let current = series.last?.value ?? .zero
        let previous = series.count > 1 ? series[series.count - 2].value : .zero
        let monthSummary = BalanceEngine.summary(entries: all, in: cal.monthRange(.now), scope: space)

        // קבלות: רק הוצאות עסקיות מאושרות
        let bizExpenses = entries.filter { $0.scope == .business && $0.kind == .expense && $0.status == .confirmed }
            .sorted { $0.date > $1.date }
        let period = VatEngine.period(containing: .now, settings: vat, calendar: cal)
        let inPeriod = bizExpenses.filter { period.contains($0.date) }
        let missing = inPeriod.filter { $0.receiptImage == nil }.count
        let streak = Streaks.receipts(hasReceiptNewestFirst: bizExpenses.prefix(60).map { $0.receiptImage != nil })

        let since = IncomeReceipts.since
        let awaitingIncome = entries.filter { IncomeReceipts.isAwaiting($0, since: since) }.count
        let share: Money? = (isBusiness && partnerBP > 0 && current.isPositive) ? current.multiplied(byBasisPoints: partnerBP) : nil
        let saved = monthSummary.net
        let companion = CompanionAdvisor.message(CompanionInput(
            isBusiness: isBusiness, pendingCount: d.pendingReviewCount, missingReceipts: missing, receiptStreak: streak,
            changeBP: MonthlySeries.changeBP(current: current, previous: previous), isRecordMonth: MonthlySeries.isRecord(series),
            savedThisMonth: saved, savingsTarget: Money(minorUnits: Int64(savingsMinor)), dayOfMonth: cal.day(.now),
            incomesAwaitingReceipt: awaitingIncome))

        return Model(dashboard: d, series: series, headline: isBusiness ? current : d.safeToSpend,
                     changeBP: MonthlySeries.changeBP(current: current, previous: previous), isRecord: MonthlySeries.isRecord(series),
                     partnerShare: share, missingReceipts: missing, periodExpenseCount: inPeriod.count, streak: streak,
                     savedThisMonth: saved, monthIncome: monthSummary.income, monthExpenses: monthSummary.netExpenses,
                     companion: companion)
    }

    // MARK: מסך

    var body: some View {
        let m = buildModel()
        ScrollView {
            VStack(spacing: 14) {
                header
                if accounts.filter({ !$0.isArchived }).isEmpty {
                    EmptyStateView(symbol: "building.columns", title: "בוא נתחיל",
                                   message: "הוסף חשבון בנק, מזומן או כרטיס אשראי עם היתרה הנוכחית שלו. אחר כך אפשר להוסיף הכנסות והוצאות.",
                                   actionTitle: "הוספת חשבון ראשון") { showAddAccount = true }
                        .card()
                }
                heroCard(m)
                if m.dashboard.pendingReviewCount > 0 { pendingCard(m.dashboard.pendingReviewCount) }
                NavigationLink {
                    if isBusiness && m.companion.text.contains("קבלה") && m.companion.text.contains("הכנס") { ReceiptsHubView() }
                    else { AdvisorChatView() }
                } label: { CompanionCard(message: m.companion) }
                    .buttonStyle(.plain)
                HStack(spacing: 10) {
                    if isBusiness {
                        streakTile(m)
                        receiptsTile(m)
                    } else {
                        challengeTile(m)
                        monthTile(m)
                    }
                }
                if let w = m.dashboard.warnings.first {
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                Color.clear.frame(height: 4)
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { quickAddBar }
        .sheet(isPresented: $showAddAccount) { NavigationStack { AccountEditorView(account: nil) } }
        .sheet(isPresented: $showReceiptCapture) { NavigationStack { ExpenseReceiptCaptureView() } }
        .onAppear { celebrate(m) }
    }

    // MARK: חלקים

    private var greeting: String {
        switch cal.calendar.component(.hour, from: .now) {
        case 5..<12: return "בוקר טוב"
        case 12..<17: return "צהריים טובים"
        case 17..<22: return "ערב טוב"
        default: return "לילה טוב"
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(Fmt.monthYear(.now)).font(.subheadline).foregroundStyle(Theme.mutedText)
            }
            Spacer()
            HStack(spacing: 2) {
                spaceButton(.business, "עסקי")
                spaceButton(.personal, "אישי")
            }
            .padding(3)
            .background(Theme.surface, in: Capsule())
            .sensoryFeedback(.selection, trigger: spaceRaw)
        }
        .padding(.top, 8)
    }

    private func spaceButton(_ s: Scope, _ title: String) -> some View {
        let selected = space == s
        return Button { withAnimation(.snappy) { spaceRaw = s.rawValue } } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(selected ? Theme.onGold : Theme.mutedText)
                .background(selected ? Theme.gold : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func heroCard(_ m: Model) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isBusiness ? "העסק הרוויח החודש · אחרי מע״מ" : "נשאר לך לשימוש החודש")
                .font(.subheadline).foregroundStyle(Theme.mutedText)
            MoneyText(money: m.headline, font: .system(size: 46, weight: .bold, design: .rounded),
                      color: m.headline.isNegative ? Theme.expense : Theme.goldBright)
                .animation(.snappy, value: m.headline)
            HStack(spacing: 8) {
                if let c = m.changeBP {
                    Label("\(abs(c) / 100)% מהחודש שעבר", systemImage: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(c >= 0 ? Theme.income : Theme.expense)
                        .background((c >= 0 ? Theme.income : Theme.expense).opacity(0.14), in: Capsule())
                }
                if m.isRecord {
                    Text("🏆 שיא").font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(Theme.goldBright).background(Theme.gold.opacity(0.15), in: Capsule())
                }
            }
            if let share = m.partnerShare {
                Text("לך \(MoneyFormat.string(m.headline - share)) · ל\(partnerName) \(MoneyFormat.string(share))")
                    .font(.footnote).foregroundStyle(Theme.mutedText)
            } else if !isBusiness {
                Text("אחרי חיובים קבועים, יעד חיסכון וכרית ביטחון · תחזית")
                    .font(.footnote).foregroundStyle(Theme.mutedText)
            }
            MiniBars(points: m.series).frame(height: 54).padding(.top, 4)
        }
        .card()
    }

    private func pendingCard(_ count: Int) -> some View {
        Button { router.showPending = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "applelogo").font(.title3).foregroundStyle(Theme.onGold)
                    .frame(width: 40, height: 40).background(Theme.gold, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "רכישה אחת מחכה לאישור" : "\(count) רכישות מחכות לאישור").font(.headline)
                    Text("Apple Pay וחיובים קבועים").font(.caption).foregroundStyle(Theme.mutedText)
                }
                Spacer()
                Image(systemName: "chevron.left").foregroundStyle(Theme.mutedText)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private func smallTile<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Theme.mutedText)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 0.5))
    }

    private func streakTile(_ m: Model) -> some View {
        NavigationLink { ExpenseReceiptsListView() } label: {
            smallTile("🔥 סדרת קבלות") {
                Text(m.streak == 1 ? "קבלה אחת" : "\(m.streak) ברצף")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.goldBright)
                Text(m.streak == 0 ? "צלם את הקבלה הבאה" : "הוצאות עם צילום").font(.caption2).foregroundStyle(Theme.mutedText)
            }
        }
        .buttonStyle(.plain)
    }

    private func receiptsTile(_ m: Model) -> some View {
        let done = m.periodExpenseCount - m.missingReceipts
        return NavigationLink { BusinessPeriodReportView() } label: {
            smallTile("קבלות בתקופה") {
                Text("\(done)/\(m.periodExpenseCount)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                ProgressView(value: m.periodExpenseCount == 0 ? 1 : Double(done) / Double(m.periodExpenseCount))
                    .tint(m.missingReceipts == 0 ? Theme.income : Theme.gold)
            }
        }
        .buttonStyle(.plain)
    }

    private func challengeTile(_ m: Model) -> some View {
        let target = Money(minorUnits: Int64(savingsMinor))
        return NavigationLink { SavingsView() } label: {
            smallTile("🎯 אתגר החודש") {
                if target.isPositive {
                    let saved = m.savedThisMonth.isPositive ? m.savedThisMonth : .zero
                    let ratio = min(1, Double(saved.minorUnits) / Double(target.minorUnits))
                    ProgressView(value: ratio).tint(ratio >= 1 ? Theme.income : Theme.gold)
                    Text("חסכת \(MoneyFormat.string(saved)) מ-\(MoneyFormat.string(target))").font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text("הגדר יעד חיסכון").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.goldBright)
                    Text("ונתחיל אתגר").font(.caption2).foregroundStyle(Theme.mutedText)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func monthTile(_ m: Model) -> some View {
        NavigationLink { TransactionsView() } label: {
            smallTile("הוצאות החודש") {
                MoneyText(money: m.monthExpenses, font: .system(size: 22, weight: .bold, design: .rounded))
                Text("הכנסות \(MoneyFormat.string(m.monthIncome))").font(.caption2).foregroundStyle(Theme.mutedText)
            }
        }
        .buttonStyle(.plain)
    }

    /// פס הוספה מהירה קבוע מעל סרגל הלשוניות — לא מכסה תוכן (safeAreaInset)
    private var quickAddBar: some View {
        HStack(spacing: 10) {
            Button { router.showQuickAdd = .expense } label: {
                Label("הוצאה", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.gold)
            if isBusiness {
                Button { showReceiptCapture = true } label: {
                    Image(systemName: "camera.fill").font(.headline).frame(width: 54, height: 52)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("צילום קבלת הוצאה")
            }
            Button { router.showQuickAdd = .income } label: {
                Label("הכנסה", systemImage: "plus").font(.headline).foregroundStyle(Theme.income)
                    .padding(.horizontal, 16).frame(minHeight: 52)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    private func celebrate(_ m: Model) {
        let key = cal.monthKey(.now)
        if isBusiness && m.isRecord && cal.day(.now) >= 10 {
            Celebrations.shared.celebrate("record-\(key)", message: "חודש שיא לעסק! 🏆")
        }
        let target = Money(minorUnits: Int64(savingsMinor))
        if !isBusiness && target.isPositive && m.savedThisMonth >= target {
            Celebrations.shared.celebrate("savings-\(key)", message: "עמדת ביעד החיסכון! 🎉")
        }
    }
}

/// גרף עמודות קטן של 6 חודשים — החודש הנוכחי בזהב
struct MiniBars: View {
    var points: [MonthPoint]

    var body: some View {
        let maxAbs = max(1, points.map { abs($0.value.minorUnits) }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                let isLast = i == points.count - 1
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(p.value.isNegative ? Theme.expense.opacity(0.6) : (isLast ? Theme.gold : Theme.hairline))
                        .frame(height: max(4, 36 * CGFloat(abs(p.value.minorUnits)) / CGFloat(maxAbs)))
                    Text(Fmt.shortMonth(p.monthStart)).font(.system(size: 10)).foregroundStyle(isLast ? Theme.goldBright : Theme.mutedText)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}
