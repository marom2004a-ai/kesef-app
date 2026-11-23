import SwiftUI
import SwiftData

// MARK: - עיצוב

enum Theme {
    static let accent = Color("AccentColor")
    static let income = Color(red: 0.12, green: 0.55, blue: 0.38)
    static let expense = Color(red: 0.78, green: 0.25, blue: 0.22)
    static let forecast = Color(red: 0.36, green: 0.40, blue: 0.80)
    static let warning = Color.orange
    static let corner: CGFloat = 22
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

enum Fmt {
    static let cal = FinanceCalendar.israel
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL"); f.calendar = cal.calendar; f.timeZone = cal.calendar.timeZone
        f.dateFormat = format
        return f
    }
    static let dateF = formatter("dd.MM.yyyy")
    static let dateTimeF = formatter("dd.MM.yyyy · HH:mm")
    static let dayMonthF = formatter("d בMMMM")
    static let monthYearF = formatter("LLLL yyyy")
    static let shortMonthF = formatter("LLL")
    static func date(_ d: Date) -> String { dateF.string(from: d) }
    static func dateTime(_ d: Date) -> String { dateTimeF.string(from: d) }
    static func dayMonth(_ d: Date) -> String { dayMonthF.string(from: d) }
    static func monthYear(_ d: Date) -> String { monthYearF.string(from: d) }
    static func shortMonth(_ d: Date) -> String { shortMonthF.string(from: d) }
    static func relative(_ d: Date, now: Date = .now) -> String {
        let days = cal.daysBetween(d, now)
        switch days {
        case 0: return "היום"
        case 1: return "אתמול"
        case let n where n > 1 && n < 30: return "לפני \(n) ימים"
        default: return date(d)
        }
    }
    static func percent(_ bp: Int) -> String { "\(bp / 100)%" }
}

// MARK: - רכיבים

struct MoneyText: View {
    var money: Money
    var font: Font = .body
    var colored: Bool = false
    var showPlus: Bool = false

    var body: some View {
        Text(MoneyFormat.string(money, showPlus: showPlus))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(colored ? (money.isNegative ? Theme.expense : (money.isPositive ? Theme.income : .primary)) : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// מבדיל בבירור בין נתון מאומת לתחזית
struct DataKindBadge: View {
    var isForecast: Bool
    var body: some View {
        Label(isForecast ? "תחזית" : "מאומת", systemImage: isForecast ? "chart.line.uptrend.xyaxis" : "checkmark.seal.fill")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(isForecast ? Theme.forecast : Theme.income)
            .background((isForecast ? Theme.forecast : Theme.income).opacity(0.12), in: Capsule())
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// שדה סכום גדול. הטקסט מפוענח ל-Money בלי Double.
struct AmountField: View {
    @Binding var text: String
    var placeholder: String = "0"
    @FocusState private var focused: Bool
    var autoFocus: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .environment(\.layoutDirection, .leftToRight)
                .focused($focused)
            Text("₪").font(.system(size: 30, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        }
        .environment(\.layoutDirection, .leftToRight)
        .onAppear { if autoFocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } } }
    }

    var money: Money? { AmountParser.parse(text)?.absolute }
}

/// בחירה בין אישי לעסקי — שני כפתורים גדולים
struct ScopePicker: View {
    @Binding var selection: Scope
    var personalTitle = "אישית"
    var businessTitle = "עסקית"

    var body: some View {
        HStack(spacing: 10) {
            button(.personal, personalTitle, "person.fill")
            button(.business, businessTitle, "briefcase.fill")
        }
    }

    private func button(_ s: Scope, _ title: String, _ symbol: String) -> some View {
        let selected = selection == s
        return Button {
            withAnimation(.snappy) { selection = s }
        } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Theme.accent : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// קטגוריות כשבבים, מסוננות לפי אישי/עסקי והכנסה/הוצאה
struct CategoryChips: View {
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Binding var selection: UUID?
    var scope: Scope
    var isIncome: Bool

    var filtered: [Category] {
        categories.filter { $0.scope == scope && $0.isIncome == isIncome && !$0.isArchived && $0.parentID == nil }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            ForEach(filtered) { c in
                let selected = selection == c.id
                Button { selection = c.id } label: {
                    VStack(spacing: 4) {
                        Image(systemName: c.symbol).font(.title3)
                        Text(c.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(selected ? Theme.accent : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SubcategoryPicker: View {
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    var parentID: UUID?
    @Binding var selection: UUID?

    var body: some View {
        let subs = categories.filter { $0.parentID != nil && $0.parentID == parentID && !$0.isArchived }
        if !subs.isEmpty {
            Picker("תת-קטגוריה", selection: $selection) {
                Text("ללא").tag(UUID?.none)
                ForEach(subs) { Text($0.name).tag(Optional($0.id)) }
            }
        }
    }
}

struct AccountPicker: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    var title: String = "חשבון"
    @Binding var selection: UUID?
    var allowNone = true

    var body: some View {
        Picker(title, selection: $selection) {
            if allowNone { Text("לא נבחר").tag(UUID?.none) }
            ForEach(accounts.filter { !$0.isArchived }) { a in
                Label(a.name, systemImage: a.kind.symbol).tag(Optional(a.id))
            }
        }
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// הצגת שגיאה אמיתית למשתמש (לא מסתירים כשלים)
struct ErrorBanner: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.expense, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// שמות קטגוריות/חשבונות לפי מזהה — לשימוש ברשימות
struct NameLookup {
    var categories: [UUID: Category]
    var accounts: [UUID: Account]
    init(categories: [Category], accounts: [Account]) {
        self.categories = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }
    func category(_ id: UUID?) -> String { id.flatMap { categories[$0]?.name } ?? "ללא קטגוריה" }
    func symbol(_ id: UUID?) -> String { id.flatMap { categories[$0]?.symbol } ?? "tag" }
    func account(_ id: UUID?) -> String? { id.flatMap { accounts[$0]?.name } }
}
