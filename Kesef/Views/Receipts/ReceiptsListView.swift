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
        let monthTotal = items.filter { cal.monthRange(.now).contains($0.date) && ($0.type?.recordsPayment ?? false) && $0.cancelledByNumber == nil }.map(\.amount).sum()
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
                if let n = d.cancelledByNumber {
                    Text("בוטל (זיכוי \(n))").font(.caption2.weight(.semibold)).foregroundStyle(Theme.expense)
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
    @State private var confirmCancel = false
    @State private var cancelling = false
    @State private var cancelError: String?
    @State private var creditURL: URL?
    @AppStorage(MorningService.envKey) private var envRaw = MorningService.Environment.demo.rawValue
    @AppStorage(AppSettings.Key.vatRegistered) private var vatRegistered = true

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
            cancelSection
            if !doc.isReal {
                Section {
                    Button("מחיקת מסמך ההדגמה מהרשימה", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle("פרטי מסמך")
        .kesefScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("סגירה") { dismiss() } } }
        .confirmationDialog("למחוק את מסמך ההדגמה?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) { context.delete(doc); try? context.save(); dismiss() }
        }
        .confirmationDialog("לבטל את המסמך בחשבונית זיכוי?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button(doc.isReal ? "הפקת חשבונית זיכוי — רשמית" : "הפקת חשבונית זיכוי (ניסיון)", role: .destructive) { cancelDocument() }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text(doc.isReal
                 ? "תופק חשבונית זיכוי רשמית ב-morning על \(MoneyFormat.string(doc.amount)), והלקוח יקבל אותה במייל אם הוזן. ההכנסה תבוטל באפליקציה (גם מהמע״מ ומהחלוקה עם השותף). אי אפשר לבטל את הביטול."
                 : "תופק חשבונית זיכוי בסביבת \(doc.environmentRaw == "demo" ? "ההדגמה" : "הניסיון") — לא אמיתית.")
        }
    }

    // MARK: ביטול מסמך (חשבונית זיכוי)

    @ViewBuilder private var cancelSection: some View {
        if let n = doc.cancelledByNumber {
            Section {
                Label("המסמך בוטל בחשבונית זיכוי מס׳ \(n)", systemImage: "xmark.seal.fill").foregroundStyle(Theme.expense)
                if let creditURL {
                    ShareLink(item: creditURL) { Label("שליחת חשבונית הזיכוי ללקוח", systemImage: "square.and.arrow.up") }
                    Link(destination: creditURL) { Label("פתיחת חשבונית הזיכוי", systemImage: "doc.richtext") }
                }
            }
        } else if doc.type?.isCancellableByCredit == true {
            Section {
                if let cancelError { ErrorBanner(message: cancelError) }
                Button(role: .destructive) { prepareCancel() } label: {
                    HStack {
                        if cancelling { ProgressView() }
                        Label("ביטול המסמך (חשבונית זיכוי)", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                .disabled(cancelling)
            } footer: {
                Text("לפי החוק מסמך מס לא נמחק — מבטלים אותו בחשבונית זיכוי. המסמך המקורי יסומן כמבוטל ב-morning.")
            }
        } else if doc.isReal {
            Section {
                Text("קבלה רגילה מבטלים ישירות ב-morning (ביטול קבלה).").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func prepareCancel() {
        cancelError = nil
        // הביטול חייב לעבור באותה סביבה שבה המסמך הופק (מפתחות שונים לכל סביבה)
        guard envRaw == doc.environmentRaw else {
            let name = ["demo": "הדגמה", "sandbox": "ניסיון", "production": "אמיתי"][doc.environmentRaw] ?? doc.environmentRaw
            cancelError = "המסמך הופק במצב \(name). כדי לבטל אותו — עבור למצב \(name) בהגדרות morning (⚙️ במסך ההכנסה)."
            return
        }
        guard let env = MorningService.Environment(rawValue: doc.environmentRaw), MorningService.isConfigured(env) else {
            cancelError = "morning לא מחובר בסביבה הזו."
            return
        }
        confirmCancel = true
    }

    private func cancelDocument() {
        guard let type = doc.type else { return }
        cancelling = true
        let draft = MorningDocumentDraft.cancellation(
            ofDocumentID: doc.externalID, originalType: type, clientName: doc.clientName,
            clientEmail: doc.clientEmail.isEmpty ? nil : doc.clientEmail, itemDescription: doc.itemDescription,
            amountIncludingVAT: doc.amount, vatExempt: !vatRegistered, payment: doc.payment ?? .other, date: .now)
        Task {
            do {
                let credit = try await MorningService.createDocument(draft)
                let saved = IssuedDocument(externalID: credit.id, number: credit.number, type: .creditInvoice,
                                           clientName: doc.clientName, clientEmail: doc.clientEmail,
                                           itemDescription: draft.itemDescription, amount: doc.amount, vat: doc.vat,
                                           payment: doc.payment ?? .other, date: .now, url: credit.url, environment: doc.environmentRaw)
                saved.entryID = doc.entryID
                context.insert(saved)
                doc.cancelledByNumber = credit.number
                // במצב אמיתי — ההכנסה המקושרת מבוטלת (יוצאת מהמע״מ, מהרווח ומהחלוקה)
                if doc.isReal, let id = doc.entryID, let e = Ledger(context: context).entry(id: id) {
                    e.status = .cancelled
                    e.note = (e.note.isEmpty ? "" : e.note + "\n") + "בוטלה בחשבונית זיכוי מס׳ \(credit.number)"
                    e.updatedAt = .now
                }
                try context.save()
                creditURL = credit.url
                Task { await AppLifecycle.refresh() }
            } catch {
                cancelError = "הביטול נכשל: \(error.localizedDescription)"
            }
            cancelling = false
        }
    }
}
