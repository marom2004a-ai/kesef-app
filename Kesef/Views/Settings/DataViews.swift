import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - גיבוי ושחזור

struct BackupView: View {
    @Environment(\.modelContext) private var context
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var pending: BackupService.BackupFile?
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button { makeBackup() } label: { Label("יצירת קובץ גיבוי", systemImage: "externaldrive.badge.plus") }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("שמירה ב-Files / iCloud Drive", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                Text("הגיבוי כולל את כל הנתונים וסכום ביקורת SHA-256. הקובץ עצמו אינו מוצפן — שמור אותו במקום מאובטח (למשל iCloud Drive שלך).")
            }
            Section {
                Button { importing = true } label: { Label("שחזור מקובץ גיבוי", systemImage: "arrow.counterclockwise") }
            } footer: {
                Text("הקובץ נבדק (פורמט, סכום ביקורת, מזהים כפולים) לפני שמשהו משתנה. לפני השחזור נשמר עותק ביטחון של המצב הנוכחי בתיקיית האפליקציה ב-Files.")
            }
            if let error { Section { ErrorBanner(message: error) } }
            if let message { Section { Text(message).font(.subheadline) } }
        }
        .navigationTitle("גיבוי ושחזור")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { pending = try BackupService.validate(data: try Data(contentsOf: url)); error = nil }
                catch { self.error = error.localizedDescription; pending = nil }
            case .failure(let e): error = e.localizedDescription
            }
        }
        .alert("להחליף את כל הנתונים?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("שחזור", role: .destructive) {
                guard let file = pending else { return }
                do {
                    let safety = try BackupService(context: context).restore(file)
                    message = "השחזור הושלם. עותק ביטחון של הנתונים הקודמים: \(safety.lastPathComponent)"
                    error = nil
                    Task { await AppLifecycle.refresh() }
                } catch { self.error = error.localizedDescription }
                pending = nil
            }
            Button("ביטול", role: .cancel) { pending = nil }
        } message: {
            if let p = pending {
                Text("גיבוי מ-\(Fmt.dateTime(p.createdAt)): \(p.payload.entries.count) תנועות, \(p.payload.accounts.count) חשבונות, \(p.payload.rules.count) חיובים קבועים. כל הנתונים הנוכחיים יוחלפו.")
            }
        }
    }

    private func makeBackup() {
        do { exportURL = try BackupService(context: context).exportBackup(); message = "הגיבוי נוצר. בחר היכן לשמור אותו."; error = nil }
        catch { self.error = "יצירת הגיבוי נכשלה: \(error.localizedDescription)" }
    }
}

// MARK: - ייבוא CSV

struct CSVImportView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var entries: [Entry]
    @State private var picking = false
    @State private var table: [[String]] = []
    @State private var fileName = ""
    @State private var mapping = CSVColumnMapping()
    @State private var accountID: UUID?
    @State private var scope: Scope = .business
    @State private var reportType: ReportType = .expenses
    @State private var includeDuplicates = false

    enum ReportType: String, CaseIterable, Identifiable {
        case expenses, income, bySign
        var id: String { rawValue }
        var label: String {
            switch self { case .expenses: return "דוח הוצאות"; case .income: return "דוח הכנסות"; case .bySign: return "לפי סימן (בנק)" }
        }
    }

    /// סכום חתום לפי סוג הדוח: בדוח הוצאות/הכנסות הכיוון קבוע, בלי קשר לסימן בקובץ
    private func resolved(_ r: ImportedRow) -> ImportedRow {
        var r = r
        guard let a = r.signedAmount else { return r }
        switch reportType {
        case .expenses: r.signedAmount = -a.absolute
        case .income: r.signedAmount = a.absolute
        case .bySign: break
        }
        return r
    }
    @State private var error: String?
    @State private var result: String?

    private var rows: [ImportedRow] {
        guard !table.isEmpty else { return [] }
        let fps = entries.compactMap(\.importFingerprint) + entries.filter { $0.importFingerprint == nil && $0.accountID == accountID }.map {
            CSVImportEngine.fingerprint(date: $0.date, signedAmount: $0.kind == .expense ? -$0.amount : $0.amount,
                                        description: $0.title, accountID: accountID)
        }
        return CSVImportEngine.markDuplicates(CSVImportEngine.rows(from: table, mapping: mapping).map(resolved),
                                              existingFingerprints: fps, accountID: accountID)
    }

    var body: some View {
        let preview = rows
        let toImport = preview.filter { $0.isValid && (includeDuplicates || !$0.isDuplicate) }
        Form {
            Section {
                Button { picking = true } label: { Label(table.isEmpty ? "בחירת קובץ Excel או CSV" : "קובץ: \(fileName)", systemImage: "doc") }
                Picker("סוג הדוח", selection: $reportType) { ForEach(ReportType.allCases) { Text($0.label).tag($0) } }
            } footer: { Text("דוח הוצאות או הכנסות מתוכנת הנהלת החשבונות, מרואה החשבון, מהבנק או מחברת האשראי — שמור ב-Files ובחר כאן. אם יש בדוח עמודת מע״מ, הסכום המדויק נשמר לחישוב המע״מ. האפליקציה לא מתחברת לבנק ולא מבקשת סיסמאות.") }

            if let error { Section { ErrorBanner(message: error) } }
            if let result { Section { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.income) } }

            if !table.isEmpty {
                let headers = table.first ?? []
                Section("התאמת עמודות") {
                    Toggle("השורה הראשונה היא כותרות", isOn: $mapping.hasHeader)
                    columnPicker("תאריך", selection: $mapping.dateColumn, headers: headers)
                    columnPicker("תיאור", selection: $mapping.descriptionColumn, headers: headers)
                    Picker("סכום", selection: Binding(get: { mapping.amountColumn ?? -1 }, set: { mapping.amountColumn = $0 < 0 ? nil : $0 })) {
                        Text("עמודות חובה/זכות נפרדות").tag(-1)
                        ForEach(headers.indices, id: \.self) { Text(label(headers, $0)).tag($0) }
                    }
                    if mapping.amountColumn == nil && reportType == .bySign {
                        optionalColumnPicker("חובה (יציאה)", selection: $mapping.debitColumn, headers: headers)
                        optionalColumnPicker("זכות (כניסה)", selection: $mapping.creditColumn, headers: headers)
                    } else if reportType == .bySign {
                        Toggle("סכום חיובי = הוצאה (קובץ אשראי)", isOn: $mapping.positiveIsExpense)
                    }
                    optionalColumnPicker("מע״מ (לא חובה)", selection: $mapping.vatColumn, headers: headers)
                    Toggle("תאריך בפורמט יום/חודש/שנה", isOn: $mapping.dayFirst)
                }
                Section("יעד") {
                    AccountPicker(title: "החשבון / הכרטיס", selection: $accountID)
                    ScopePicker(selection: $scope, personalTitle: "אישי", businessTitle: "עסקי")
                    Toggle("לייבא גם שורות שזוהו ככפולות", isOn: $includeDuplicates)
                }
                Section("תצוגה מקדימה — \(toImport.count) ייובאו מתוך \(preview.count)") {
                    ForEach(preview.prefix(60)) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.description.isEmpty ? "—" : r.description).lineLimit(1)
                                Text(r.date.map(Fmt.date) ?? "תאריך?").font(.caption2).foregroundStyle(.secondary)
                                if let e = r.error { Text(e).font(.caption2).foregroundStyle(Theme.expense) }
                                if r.isDuplicate { Text("כבר קיים").font(.caption2).foregroundStyle(Theme.warning) }
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                if let a = r.signedAmount { MoneyText(money: a, font: .subheadline, colored: true) }
                                if let v = r.vat { Text("מע״מ \(MoneyFormat.string(v))").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        .opacity(r.isValid && (includeDuplicates || !r.isDuplicate) ? 1 : 0.45)
                    }
                    if preview.count > 60 { Text("ועוד \(preview.count - 60) שורות…").font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Button("ייבוא \(toImport.count) תנועות") { importRows(toImport) }
                        .disabled(toImport.isEmpty || accountID == nil)
                    if accountID == nil { Text("בחר חשבון לפני הייבוא.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("ייבוא CSV")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.spreadsheet, .commaSeparatedText, .plainText, .tabSeparatedText, .data]) { res in
            switch res {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    if url.pathExtension.lowercased() == "xlsx" || data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
                        let t = try XLSXReader.readFirstSheet(data)
                        guard !t.isEmpty else { error = "הגיליון ריק."; return }
                        table = t; fileName = url.lastPathComponent; mapping = CSVImportEngine.guessMapping(t); error = nil; result = nil
                        return
                    }
                    // קובצי בנקים ישראליים מגיעים לפעמים ב-Windows-1255
                    guard let text = String(data: data, encoding: .utf8)
                            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue))))
                    else { error = "לא ניתן לקרוא את הקידוד של הקובץ."; return }
                    let t = CSVParser.parse(text)
                    guard !t.isEmpty else { error = "הקובץ ריק."; return }
                    table = t; fileName = url.lastPathComponent; mapping = CSVImportEngine.guessMapping(t); error = nil; result = nil
                } catch { self.error = error.localizedDescription }
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    private func label(_ headers: [String], _ i: Int) -> String {
        let h = i < headers.count ? headers[i] : ""
        return mapping.hasHeader && !h.isEmpty ? h : "עמודה \(i + 1)"
    }
    private func columnPicker(_ title: String, selection: Binding<Int>, headers: [String]) -> some View {
        Picker(title, selection: selection) { ForEach(headers.indices, id: \.self) { Text(label(headers, $0)).tag($0) } }
    }
    private func optionalColumnPicker(_ title: String, selection: Binding<Int?>, headers: [String]) -> some View {
        Picker(title, selection: selection) {
            Text("ללא").tag(Int?.none)
            ForEach(headers.indices, id: \.self) { Text(label(headers, $0)).tag(Optional($0)) }
        }
    }

    private func importRows(_ rows: [ImportedRow]) {
        guard let accountID else { return }
        var count = 0
        for r in rows {
            guard let date = r.date, let signed = r.signedAmount, !signed.isZero else { continue }
            let kind: EntryKind = signed.isNegative ? .expense : .income
            let e = Entry(kind: kind, status: .confirmed, amount: signed.absolute, date: date, title: r.description,
                          scope: scope, accountID: accountID, source: .csvImport)
            e.importFingerprint = CSVImportEngine.fingerprint(date: date, signedAmount: signed, description: r.description, accountID: accountID)
            e.note = "יובא מ-\(fileName)"
            e.vatMinor = r.vat?.minorUnits
            context.insert(e)
            count += 1
        }
        do {
            try context.save()
            result = "יובאו \(count) תנועות. מומלץ לעבור עליהן ולסווג קטגוריות במסך התנועות."
            table = []
        } catch { self.error = "הייבוא נכשל ולא נשמר דבר: \(error.localizedDescription)"; context.rollback() }
    }
}
