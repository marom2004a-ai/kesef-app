import SwiftUI
import SwiftData

// MARK: - עיצוב

enum Theme {
    /// זהב ענבר — צבע הנגיעה הראשי
    static let accent = Color("AccentColor")
    static let gold = Color(red: 0.878, green: 0.659, blue: 0.306)        // #E0A84E
    static let goldBright = Color(red: 0.910, green: 0.714, blue: 0.361)  // #E8B65C
    static let onGold = Color(red: 0.165, green: 0.106, blue: 0.020)      // טקסט על זהב
    static let background = Color(red: 0.071, green: 0.067, blue: 0.063) // #121110
    static let surface = Color(red: 0.110, green: 0.102, blue: 0.090)     // #1C1A17
    static let surfaceHigh = Color(red: 0.150, green: 0.140, blue: 0.125)
    static let hairline = Color(red: 0.227, green: 0.196, blue: 0.141)    // #3A3224
    static let mutedText = Color(red: 0.659, green: 0.624, blue: 0.565)   // #A89F90
    static let income = Color(red: 0.62, green: 0.83, blue: 0.54)         // ירוק רך
    static let expense = Color(red: 0.93, green: 0.50, blue: 0.42)        // אלמוג
    static let forecast = Color(red: 0.55, green: 0.62, blue: 0.95)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.30)
    static let corner: CGFloat = 22
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 0.5))
    }
}

/// רקע כהה-חם לכל מסך (רשימות וטפסים מקבלים אותו גוון)
struct KesefScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}

/// כפתור ראשי: זהב עם טקסט כהה (ניגודיות טובה יותר מלבן על זהב)
struct GoldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.onGold)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background((isEnabled ? Theme.gold : Theme.gold.opacity(0.35)).opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GoldButtonStyle {
    static var gold: GoldButtonStyle { GoldButtonStyle() }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
    func kesefScreen() -> some View { modifier(KesefScreen()) }
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
    /// צבע קבוע (למשל זהב לסכום הראשי) — גובר על colored
    var color: Color? = nil

    var body: some View {
        Text(MoneyFormat.string(money, showPlus: showPlus))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color ?? (colored ? (money.isNegative ? Theme.expense : (money.isPositive ? Theme.income : .primary)) : .primary))
            .contentTransition(.numericText())
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
                Button(actionTitle, action: action).buttonStyle(.gold).padding(.top, 4)
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
