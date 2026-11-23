import SwiftUI
import SwiftData

/// רשימת הלקוחות השמורים — עם פרטי קשר ובנק, כדי שהכנסה וקבלה יתמלאו לבד
struct ClientsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]
    @State private var search = ""
    @State private var editing: Client?
    @State private var adding = false

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? clients : clients.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.phone.contains(q) }
        List {
            if clients.isEmpty {
                EmptyStateView(symbol: "person.2", title: "עוד אין לקוחות שמורים",
                               message: "כל לקוח שתרשום לו הכנסה נשמר כאן אוטומטית, עם פרטי הבנק ואמצעי התשלום — ובפעם הבאה הכול מתמלא לבד.")
                    .listRowBackground(Color.clear)
            }
            ForEach(list) { c in
                Button { editing = c } label: {
                    HStack(spacing: 12) {
                        Text(String(c.name.prefix(1)))
                            .font(.headline).foregroundStyle(Theme.onGold)
                            .frame(width: 38, height: 38).background(Theme.gold, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).lineLimit(1)
                            Text([c.preferredPayment?.label, c.hasBankDetails ? "פרטי בנק שמורים" : nil,
                                  c.useCount > 0 ? "\(c.useCount) הכנסות" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.mutedText)
                        }
                        Spacer()
                        if c.lastAmount.isPositive { MoneyText(money: c.lastAmount, font: .subheadline) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { idx in
                for i in idx { context.delete(list[i]) }
                try? context.save()
            }
        }
        .searchable(text: $search, prompt: "חיפוש לקוח")
        .navigationTitle("לקוחות")
        .kesefScreen()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("לקוח חדש")
            }
        }
        .sheet(item: $editing) { c in NavigationStack { ClientEditorView(client: c) } }
        .sheet(isPresented: $adding) { NavigationStack { ClientEditorView(client: nil) } }
    }
}

struct ClientEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    let client: Client?

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var taxId = ""
    @State private var bankName = ""
    @State private var bankBranch = ""
    @State private var bankAccount = ""
    @State private var payment: MorningPaymentMethod?
    @State private var categoryID: UUID?
    @State private var description = ""
    @State private var note = ""
    @State private var newIncome = false

    var body: some View {
        Form {
            Section("פרטים") {
                TextField("שם", text: $name)
                TextField("מייל", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().environment(\.layoutDirection, .leftToRight)
                TextField("נייד", text: $phone).keyboardType(.phonePad)
                TextField("ח״פ / ת״ז (לא חובה)", text: $taxId).keyboardType(.numberPad)
            }
            Section("ברירות מחדל להכנסה") {
                Picker("אמצעי תשלום", selection: $payment) {
                    Text("לא נבחר").tag(MorningPaymentMethod?.none)
                    ForEach(MorningPaymentMethod.allCases) { Text($0.label).tag(Optional($0)) }
                }
                Picker("שירות", selection: $categoryID) {
                    Text("לא נבחר").tag(UUID?.none)
                    ForEach(categories.filter { $0.scope == .business && $0.isIncome && !$0.isArchived }) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("תיאור בקבלה", text: $description)
            }
            Section("פרטי בנק (לצ׳קים והעברות)") {
                TextField("בנק", text: $bankName)
                TextField("סניף", text: $bankBranch).keyboardType(.numberPad)
                TextField("מספר חשבון", text: $bankAccount).keyboardType(.numberPad)
            }
            Section { TextField("הערה", text: $note, axis: .vertical) }
            if client != nil {
                Section {
                    Button { newIncome = true } label: { Label("הכנסה + קבלה ללקוח הזה", systemImage: "doc.badge.plus") }
                }
            }
        }
        .kesefScreen()
        .navigationTitle(client == nil ? "לקוח חדש" : "עריכת לקוח")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("שמירה") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $newIncome) { NavigationStack { BusinessIncomeView(prefillClientID: client?.id) } }
    }

    private func load() {
        guard let c = client, name.isEmpty else { return }
        name = c.name; email = c.email; phone = c.phone; taxId = c.taxId
        bankName = c.bankName; bankBranch = c.bankBranch; bankAccount = c.bankAccount
        payment = c.preferredPayment; categoryID = c.defaultCategoryID; description = c.defaultDescription; note = c.note
    }

    private func save() {
        let c = client ?? { let n = Client(name: name); context.insert(n); return n }()
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.email = email.trimmingCharacters(in: .whitespaces); c.phone = phone; c.taxId = taxId
        c.bankName = bankName; c.bankBranch = bankBranch; c.bankAccount = bankAccount
        c.preferredPayment = payment; c.defaultCategoryID = categoryID; c.defaultDescription = description; c.note = note
        try? context.save()
        dismiss()
    }
}
