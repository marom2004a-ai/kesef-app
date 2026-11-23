import XCTest
@testable import Kesef

/// בונה קובץ xlsx מינימלי בזיכרון (ZIP עם קובץ דחוס ב-DEFLATE ואחד לא דחוס) ובודק שהקורא מפענח אותו.
final class XLSXReaderTests: XCTestCase {

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    private func le32(_ v: Int) -> [UInt8] { le16(v & 0xffff) + le16((v >> 16) & 0xffff) }

    private func makeZip(_ files: [(String, Data, Bool)]) throws -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for (name, content, deflate) in files {
            let payload: Data = deflate ? try (content as NSData).compressed(using: .zlib) as Data : content
            let nameBytes = Array(name.utf8)
            let offset = out.count
            out += le32(0x04034b50) + le16(20) + le16(0) + le16(deflate ? 8 : 0) + le16(0) + le16(0)
            out += le32(0) + le32(payload.count) + le32(content.count) + le16(nameBytes.count) + le16(0)
            out += nameBytes + Array(payload)
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(deflate ? 8 : 0) + le16(0) + le16(0)
            central += le32(0) + le32(payload.count) + le32(content.count) + le16(nameBytes.count) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
        }
        let cdOffset = out.count
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(cdOffset) + le16(0)
        return Data(out)
    }

    func testReadsSharedStringsNumbersAndGaps() throws {
        let shared = """
        <?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <si><t>תאריך</t></si><si><t>ספק</t></si><si><t>סכום כולל מע"מ</t></si><si><t>מע"מ</t></si><si><r><t>חנות </t></r><r><t>חיות</t></r></si></sst>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row>
        <row r="2"><c r="A2"><v>46331</v></c><c r="B2" t="s"><v>4</v></c><c r="C2"><v>1180</v></c><c r="D2"><v>180</v></c></row>
        <row r="4"><c r="A4" t="inlineStr"><is><t>06/11/2026</t></is></c><c r="C4"><v>236.5</v></c></row>
        </sheetData></worksheet>
        """
        let zip = try makeZip([("xl/sharedStrings.xml", Data(shared.utf8), true),
                               ("xl/worksheets/sheet1.xml", Data(sheet.utf8), false)])
        let table = try XLSXReader.readFirstSheet(zip)
        XCTAssertEqual(table.count, 3)
        XCTAssertEqual(table[0], ["תאריך", "ספק", "סכום כולל מע\"מ", "מע\"מ"])
        XCTAssertEqual(table[1], ["46331", "חנות חיות", "1180", "180"])
        XCTAssertEqual(table[2], ["06/11/2026", "", "236.5", ""])

        // מקצה לקצה: אותה טבלה עוברת במנוע הייבוא
        let m = CSVImportEngine.guessMapping(table)
        let rows = CSVImportEngine.rows(from: table, mapping: m)
        XCTAssertEqual(rows[0].signedAmount, Money(shekels: 1180))
        XCTAssertEqual(rows[0].vat, Money(shekels: 180))
        XCTAssertEqual(rows[1].signedAmount, Money(minorUnits: 23650))
    }

    func testRejectsNonZip() {
        XCTAssertThrowsError(try XLSXReader.readFirstSheet(Data("תאריך,סכום\n".utf8)))
    }
}
