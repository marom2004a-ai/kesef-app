import SwiftUI
import SwiftData

/// "הקבלות שלי" — ארכיון כל המסמכים שהופקו מהאפליקציה
struct ReceiptsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \IssuedDocument.createdAt, order: .reverse) private var docs: [IssuedDocument]
    @State private var showDemo = false
    @State private var search = ""
    @State private var selected: IssuedDocument?

    private let cal = FinanceCalendar.israel

    private var filtered: [IssuedDocument] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return docs.filter { d in
            (showDemo || d.isReal) &&
            (q.isEmpty || d.clientName.localizedCaseInsensitiveContains(q) || d.itemDescription.localizedCaseInsensitiveContains(q) || String(d.number).contains(q))
        }
    }

    var body: some View {
        let items = filtered
        let groups = Dictionary(grouping: items) { cal.startOfMonth($0.date) }.sorted { $0.key > $1.key }
        let monthTotal = items.filter { cal.monthRange(.now).contains($0.date) && ($0.type?.recordsPayment ?? false) }.map(\.amount).sum()
        List {
            Section {
                NavigationLink { IssueReceiptView() } label: {
                    Label("הפקת קבלה / חשבונית חדשה", systemImage: "plus.circle.fill").font(.headline)
                }
                LabeledContent("נגבה החודש (לפי קבלות)") { MoneyText(money: monthTotal, font: .headline) }
                Toggle("להציג גם מסמכי הדגמה וניסיון", isOn: $showDemo)
            }
            if items.isEmpty {
                EmptyStateView(symbol: "doc.text", title: "אין עדיין מסמכים",
                               message: showDemo ? "מסמכים שתפיק יופיעו כאן." : "מסמכים אמיתיים שתפיק דרך morning יופיעו כאן. כדי לראות מסמכי הדגמה — הפעל את המתג למעלה.")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.key) { month, list in
                Section(Fmt.monthYear(month)) {
                    ForEach(list) { d in
                        Button { selected = d } label: { row(d) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "חיפוש לפי לקוח, תיאור או מספר")
        .navigationTitle("הקבלות שלי")
        .kesefScreen()
        .sheet(item: $selected) { d in NavigationStack { ReceiptDetailView(doc: d) } }
    }

    private func row(_ d: IssuedDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill").foregroundStyle(d.isReal ? Theme.accent : Color.secondary)
                .frame(width: 36, height: 36).background(Color(.tertiarySystemFill), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(d.clientName).lineLimit(1)
                Text("\(d.type?.label ?? "מסמך") מס׳ \(d.number) · \(Fmt.date(d.date))")
                    .font(.caption).foregroundStyle(.secondary)
                if !d.isReal {
                    Text(d.environmentRaw == "demo" ? "הדגמה" : "ניסיון").font(.caption2.weight(.semibold)).foregroundStyle(Theme.warning)
                }
            }
            Spacer()
            MoneyText(money: d.amount, font: .body.weight(.semibold))
        }
        .contentShape(Rectangle())
    }
}

struct ReceiptDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let doc: IssuedDocument
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(doc.type?.label ?? "מסמך") מס׳ \(doc.number)").font(.title3.bold())
                    if !doc.isReal {
                        Label(doc.environmentRaw == "demo" ? "מסמך הדגמה — לא אמיתי" : "מסמך ניסיון — לא אמיתי", systemImage: "testtube.2")
                            .foregroundStyle(Theme.warning).font(.subheadline)
                    }
                }
                LabeledContent("לקוח", value: doc.clientName)
                if !doc.clientEmail.isEmpty { LabeledContent("מייל", value: doc.clientEmail) }
                LabeledContent("תיאור", value: doc.itemDescription)
                LabeledContent("תאריך", value: Fmt.date(doc.date))
                LabeledContent("אמצעי תשלום", value: doc.payment?.label ?? "—")
            }
            Section {
                LabeledContent("סכום כולל מע״מ") { MoneyText(money: doc.amount, font: .headline) }
                if doc.vat.isPositive {
                    LabeledContent("מתוכו מע״מ") { MoneyText(money: doc.vat) }
                    LabeledContent("לפני מע״מ") { MoneyText(money: doc.amount - doc.vat) }
                }
            }
            if let url = doc.url {
                Section {
                    ShareLink(item: url) { Label("שיתוף המסמך (וואטסאפ / מייל)", systemImage: "square.and.arrow.up") }
                    Link(destination: url) { Label("פתיחת המסמך", systemImage: "doc.richtext") }
                }
            } else if !doc.isReal {
                Section { Text("למסמכי הדגמה אין קובץ. במסמכים אמיתיים יופיעו כאן פתיחה ושיתוף.").font(.footnote).foregroundStyle(.secondary) }
            }
            if !doc.isReal {
                Section {
                    Button("מחיקת מסמך ההדגמה מהרשימה", role: .destructive) { confirmDelete = true }
                }
            } else {
                Section {
                    Text("מסמך מס רשמי לא ניתן למחיקה. לביטול מפיקים חשבונית זיכוי ב-morning.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("פרטי מסמך")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("סגירה") { dismiss() } } }
        .confirmationDialog("למחוק את מסמך ההדגמה?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) { context.delete(doc); try? context.save(); dismiss() }
        }
    }
}
