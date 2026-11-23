import SwiftUI
import SwiftData
import PhotosUI
import VisionKit

// MARK: - צילום קבלת הוצאה

/// צילום קבלה של הוצאה עסקית: סורק מסמכים (חיתוך אוטומטי) או בחירה מהתמונות,
/// ואז רישום הוצאה עסקית חדשה עם הצילום — או צירוף הצילום להוצאה שכבר קיימת (למשל מ-Apple Pay).
struct ExpenseReceiptCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]

    /// אם נפתח מהוצאה מסוימת — הצילום יצורף אליה
    var attachTo: Entry?

    enum Mode: String, CaseIterable, Identifiable { case new = "הוצאה חדשה", existing = "צירוף להוצאה קיימת"; var id: String { rawValue } }

    @State private var image: Data?
    @State private var showScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var mode: Mode = .new
    @State private var amountText = ""
    @State private var title = ""
    @State private var date = Date.now
    @State private var categoryID: UUID?
    @State private var accountID: UUID?
    @State private var paymentMethod: PaymentMethod = .creditCard
    @State private var selectedExisting: UUID?
    @State private var error: String?

    private var canScan: Bool { VNDocumentCameraViewController.isSupported || UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// הוצאות עסקיות מ-60 הימים האחרונים שעוד אין להן צילום
    private var candidates: [Entry] {
        let since = FinanceCalendar.israel.addDays(-60, to: .now)
        return allEntries.filter { $0.kind == .expense && $0.scope == .business && $0.status != .cancelled
            && $0.date >= since && $0.receiptImage == nil }
    }

    var body: some View {
        Form {
            if let error { Section { ErrorBanner(message: error) } }

            Section {
                if let image, let ui = UIImage(data: image) {
                    Image(uiImage: ui).resizable().scaledToFit().frame(maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                }
                Button { showScanner = true } label: {
                    Label(image == nil ? "צילום הקבלה" : "צילום מחדש", systemImage: "doc.viewfinder")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!canScan)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("בחירה מהתמונות", systemImage: "photo.on.rectangle")
                }
            } footer: {
                if image == nil { Text("הסורק מזהה את גבולות הקבלה וחותך אותה אוטומטית. אפשר גם לבחור צילום מסך או תמונה קיימת.") }
            }

            if let attachTo {
                Section("הצילום יצורף להוצאה") {
                    existingRow(attachTo)
                }
            } else {
                Section {
                    Picker("סוג", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                }
                if mode == .new { newExpenseFields } else { existingPicker }
            }
        }
        .navigationTitle("קבלת הוצאה לעסק")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("שמירה") { save() }.fontWeight(.semibold).disabled(!canSave) }
        }
        .fullScreenCover(isPresented: $showScanner) {
            ReceiptScanner { data in image = data }.ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            Task { if let data = try? await item?.loadTransferable(type: Data.self) { image = EntryEditorView.compress(data) } }
        }
        .onAppear {
            if accountID == nil {
                accountID = Ledger(context: context).accounts().first { $0.kind == .businessBank }?.id
            }
        }
    }

    private var newExpenseFields: some View {
        Group {
            Section {
                AmountField(text: $amountText, autoFocus: false).padding(.vertical, 4)
                TextField("בית עסק / ספק", text: $title)
                DatePicker("תאריך בקבלה", selection: $date, displayedComponents: .date)
            }
            Section("קטגוריה עסקית") {
                CategoryChips(selection: $categoryID, scope: .business, isIncome: false)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            Section {
                AccountPicker(title: "שולם מחשבון / כרטיס", selection: $accountID)
                Picker("אמצעי תשלום", selection: $paymentMethod) {
                    ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                }
            } footer: { Text("נרשם כהוצאה עסקית מאושרת. המע״מ מחושב אוטומטית לפי הקטגוריה.") }
        }
    }

    private var existingPicker: some View {
        Section {
            if candidates.isEmpty {
                Text("אין הוצאות עסקיות מ-60 הימים האחרונים שחסרה להן קבלה.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(candidates) { e in
                Button { selectedExisting = e.id } label: {
                    HStack {
                        Image(systemName: selectedExisting == e.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedExisting == e.id ? Theme.accent : Color.secondary)
                        existingRow(e)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: { Text("בחר את ההוצאה") }
          footer: { Text("למשל רכישה שנקלטה מ-Apple Pay — מצרפים לה את הקבלה בלי לרשום אותה פעמיים.") }
    }

    private func existingRow(_ e: Entry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title.isEmpty ? "הוצאה" : e.title).lineLimit(1)
                Text(Fmt.date(e.date)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(money: e.amount, font: .body.weight(.semibold))
        }
        .contentShape(Rectangle())
    }

    private var canSave: Bool {
        guard image != nil else { return false }
        if attachTo != nil { return true }
        switch mode {
        case .existing: return selectedExisting != nil
        case .new:
            guard let a = AmountParser.parse(amountText)?.absolute, a.isPositive else { return false }
            return !title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func save() {
        guard let image else { error = "צריך קודם לצלם את הקבלה."; return }
        do {
            if let target = attachTo ?? (mode == .existing ? candidates.first { $0.id == selectedExisting } : nil) {
                target.receiptImage = image
                target.updatedAt = .now
            } else {
                guard let amount = AmountParser.parse(amountText)?.absolute, amount.isPositive else { error = "הזן סכום תקין."; return }
                let e = Entry(kind: .expense, status: .confirmed, amount: amount, date: date,
                              title: title.trimmingCharacters(in: .whitespaces), scope: .business)
                e.categoryID = categoryID
                e.accountID = accountID
                e.paymentMethod = paymentMethod
                e.receiptImage = image
                e.confirmedAt = .now
                context.insert(e)
            }
            try context.save()
            Task { await AppLifecycle.refresh() }
            dismiss()
        } catch {
            self.error = "השמירה נכשלה: \(error.localizedDescription)"
        }
    }
}

// MARK: - סורק / מצלמה

/// סורק המסמכים של iOS (חיתוך ויישור אוטומטי). אם אינו זמין — המצלמה הרגילה.
struct ReceiptScanner: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        if VNDocumentCameraViewController.isSupported {
            let vc = VNDocumentCameraViewController()
            vc.delegate = context.coordinator
            return vc
        }
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ReceiptScanner
        init(_ parent: ReceiptScanner) { self.parent = parent }

        private func deliver(_ img: UIImage) {
            if let data = img.jpegData(compressionQuality: 0.9) { parent.onImage(EntryEditorView.compress(data)) }
            parent.dismiss()
        }

        // סורק מסמכים — העמוד הראשון הוא הקבלה
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { parent.dismiss(); return }
            deliver(scan.imageOfPage(at: 0))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.dismiss() }

        // מצלמה רגילה
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { deliver(img) } else { parent.dismiss() }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - קבלות ההוצאות

/// כל קבלות ההוצאות של העסק, לפי תקופות דיווח, ותזכורת להוצאות שחסר להן צילום.
struct ExpenseReceiptsListView: View {
    @Query(filter: #Predicate<Entry> { $0.scopeRaw == "business" && $0.kindRaw == "expense" },
           sort: \Entry.date, order: .reverse) private var expenses: [Entry]
    @AppStorage(AppSettings.Key.vatPeriodMonths) private var periodMonths = 2
    @State private var showCapture = false
    @State private var attachTo: Entry?
    @State private var viewing: Entry?
    @State private var search = ""

    private let cal = FinanceCalendar.israel

    var body: some View {
        let settings = VatSettings(isRegistered: true, periodMonths: periodMonths)
        let current = VatEngine.period(containing: .now, settings: settings, calendar: cal)
        let active = expenses.filter { $0.status == .confirmed }
        let q = search.trimmingCharacters(in: .whitespaces)
        let withPhoto = active.filter { $0.receiptImage != nil && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q)) }
        let missing = active.filter { $0.receiptImage == nil && current.contains($0.date) }
        let groups = Dictionary(grouping: withPhoto) { VatEngine.period(containing: $0.date, settings: settings, calendar: cal).lowerBound }
            .sorted { $0.key > $1.key }

        List {
            Section {
                Button { showCapture = true } label: {
                    Label("צילום קבלה חדשה", systemImage: "camera.fill").font(.headline)
                }
            }
            if !missing.isEmpty && q.isEmpty {
                Section {
                    ForEach(missing) { e in
                        Button { attachTo = e } label: {
                            HStack {
                                Image(systemName: "camera.badge.ellipsis").foregroundStyle(Theme.warning)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title.isEmpty ? "הוצאה" : e.title).lineLimit(1)
                                    Text(Fmt.date(e.date)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(money: e.amount, font: .subheadline.weight(.semibold))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("חסר צילום — התקופה הנוכחית (\(missing.count))") }
                  footer: { Text("לחיצה על הוצאה פותחת צילום קבלה בשבילה.") }
            }
            if withPhoto.isEmpty {
                EmptyStateView(symbol: "doc.text.image", title: "אין עדיין קבלות",
                               message: "צלם קבלה של הוצאה עסקית והיא תישמר כאן, מסודרת לפי תקופות הדיווח.")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.key) { start, list in
                Section("\(reportPeriodTitle(VatEngine.period(containing: start, settings: settings, calendar: cal), months: periodMonths)) · \(list.count) קבלות") {
                    ForEach(list) { e in
                        Button { viewing = e } label: { ReceiptThumbRow(entry: e) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "חיפוש לפי בית עסק")
        .navigationTitle("קבלות ההוצאות")
        .kesefScreen()
        .sheet(isPresented: $showCapture) { NavigationStack { ExpenseReceiptCaptureView() } }
        .sheet(item: $attachTo) { e in NavigationStack { ExpenseReceiptCaptureView(attachTo: e) } }
        .sheet(item: $viewing) { e in NavigationStack { ExpenseReceiptDetailView(entry: e) } }
    }
}

struct ReceiptThumbRow: View {
    let entry: Entry
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
                else { Color(.tertiarySystemFill) }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "הוצאה" : entry.title).lineLimit(1)
                Text(Fmt.date(entry.date)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(money: entry.amount, font: .body.weight(.semibold))
        }
        .contentShape(Rectangle())
        .task(id: entry.id) {
            guard thumb == nil, let data = entry.receiptImage else { return }
            thumb = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: 120, height: 120))
        }
    }
}

struct ExpenseReceiptDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let entry: Entry
    @State private var shareURL: URL?
    @State private var showEdit = false
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let data = entry.receiptImage, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title.isEmpty ? "הוצאה" : entry.title).font(.title3.bold())
                    Text(Fmt.date(entry.date)).foregroundStyle(.secondary)
                    MoneyText(money: entry.amount, font: .title2.weight(.semibold))
                }
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("שיתוף הקבלה", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                Button { showEdit = true } label: {
                    Label("עריכת ההוצאה", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("הסרת הצילום מההוצאה", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("קבלה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("סגירה") { dismiss() } } }
        .sheet(isPresented: $showEdit) { NavigationStack { EntryEditorView(existing: entry) } }
        .confirmationDialog("להסיר את צילום הקבלה?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("הסרת הצילום", role: .destructive) {
                entry.receiptImage = nil
                try? context.save()
                dismiss()
            }
        } message: { Text("ההוצאה עצמה נשארת. רק התמונה תימחק.") }
        .task {
            guard let data = entry.receiptImage else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("kabala-\(entry.id.uuidString.prefix(8)).jpg")
            if (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil { shareURL = url }
        }
    }
}
