import CoreGraphics
import CoreText
import Foundation

/// Headless, paginated PDF rendering with Core Text (works in the app, CLI and MCP server).
enum PDFRenderer {
    static let pageSize = CGSize(width: 595, height: 842) // A4 in points
    static let margin: CGFloat = 54

    static func render(document doc: MeetingExportDocument,
                       segments: [MeetingExportDocument.SegmentInfo]) throws -> Data {
        let text = NSMutableAttributedString()
        func font(_ size: CGFloat, bold: Bool = false, mono: Bool = false) -> CTFont {
            let base: CTFont = mono
                ? CTFontCreateWithName("Menlo" as CFString, size - 1, nil)
                : CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, "es" as CFString)
                    ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            return base
        }
        func color(_ gray: CGFloat) -> CGColor { CGColor(gray: gray, alpha: 1) }
        func paragraph(spacingAfter: CGFloat) -> CTParagraphStyle {
            var spacing = spacingAfter
            var lineSpacing: CGFloat = 2
            return withUnsafeBytes(of: &spacing) { spacingPtr in
                withUnsafeBytes(of: &lineSpacing) { linePtr in
                    let settings = [
                        CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size,
                                                value: spacingPtr.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
                                                value: linePtr.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
        func append(_ string: String, size: CGFloat, bold: Bool = false, mono: Bool = false,
                    gray: CGFloat = 0.1, after: CGFloat = 6) {
            text.append(NSAttributedString(string: string + "\n", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold, mono: mono),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(gray),
                paragraphKey: paragraph(spacingAfter: after),
            ]))
        }

        append(doc.meeting.title, size: 20, bold: true, after: 10)
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_CO")
        df.dateStyle = .long
        df.timeStyle = .short
        append("\(df.string(from: doc.meeting.displayDate)) · \(Timecode.humanDuration(doc.meeting.durationSeconds))",
               size: 10, gray: 0.45, after: 2)
        if !doc.participants.isEmpty {
            append("Participantes: \(doc.participants.map(\.name).joined(separator: ", "))", size: 10, gray: 0.45, after: 2)
        }
        if let t = doc.transcripts.first { append("Transcripción: \(t.model)", size: 10, gray: 0.45, after: 14) }

        if let analysis = doc.analyses.last(where: { $0.status == AnalysisStatus.succeeded.rawValue }),
           let summary = analysis.executiveSummary {
            append("Resumen ejecutivo (generado por IA · \(analysis.provider))", size: 13, bold: true, after: 6)
            append(summary, size: 10.5, after: 14)
            for category in AnalysisCategory.allCases {
                let items = analysis.items.filter { $0.category == category.rawValue }
                guard !items.isEmpty else { continue }
                append(category.displayName, size: 12, bold: true, after: 4)
                for item in items {
                    var line = "• \(item.text)"
                    if let owner = item.owner { line += " — \(owner)" }
                    if let ts = item.evidence?.timestamp { line += " [\(ts)]" }
                    if item.evidenceStatus == EvidenceStatus.unconfirmed.rawValue { line += " (información no confirmada)" }
                    append(line, size: 10, after: 3)
                }
                append("", size: 6, after: 6)
            }
        }

        append("Transcripción", size: 13, bold: true, after: 8)
        for seg in segments {
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(string: "\(Timecode.hms(seg.start))  ", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(9, mono: true),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0.5),
            ]))
            line.append(NSAttributedString(string: "\(seg.speakerName): ", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(10, bold: true),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0.15),
            ]))
            line.append(NSAttributedString(string: seg.text + "\n", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(10),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0.1),
            ]))
            line.addAttribute(paragraphKey, value: paragraph(spacingAfter: 5), range: NSRange(location: 0, length: line.length))
            text.append(line)
        }

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextTitle as String: doc.meeting.title,
                  kCGPDFContextCreator as String: doc.application,
              ] as CFDictionary) else {
            throw AppDatabaseError.invalidOperation("No se pudo crear el contexto PDF.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frameRect = CGRect(x: margin, y: margin + 18, width: pageSize.width - 2 * margin,
                               height: pageSize.height - 2 * margin - 18)
        var location = 0
        var page = 1
        while location < text.length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            // Footer: page number.
            let footer = NSAttributedString(string: "\(doc.meeting.title) · \(page)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(8),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0.6),
            ])
            let footerLine = CTLineCreateWithAttributedString(footer)
            context.textPosition = CGPoint(x: margin, y: margin - 18)
            CTLineDraw(footerLine, context)
            context.endPDFPage()
            guard visible.length > 0 else { break }
            location += visible.length
            page += 1
        }
        context.closePDF()
        return data as Data
    }
}
