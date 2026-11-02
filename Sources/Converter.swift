import AVFoundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// What a file can be turned into on the shelf.
enum FileFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic, tiff, gif, bmp, pdf
    case mp4, mov, m4a, wav, aiff, flac
    case text, rtf, html, docx, odt
    case json, plist, csv
    case zip, unzipped

    var id: String { rawValue }

    var name: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .pdf: return "PDF"
        case .mp4: return "MP4"
        case .mov: return "QuickTime movie"
        case .m4a: return "M4A audio"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .flac: return "FLAC"
        case .text: return "Plain text"
        case .rtf: return "Rich text (RTF)"
        case .html: return "Web page (HTML)"
        case .docx: return "Word (DOCX)"
        case .odt: return "OpenDocument (ODT)"
        case .json: return "JSON"
        case .plist: return "Property list"
        case .csv: return "CSV"
        case .zip: return "Zip"
        case .unzipped: return "Unzipped folder"
        }
    }

    /// The new file's extension (none for a folder).
    var fileExtension: String? {
        switch self {
        case .jpeg: return "jpg"
        case .text: return "txt"
        case .unzipped: return nil
        default: return rawValue
        }
    }

    /// The type a file already in this format has: it isn't offered for it.
    var type: UTType? {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        case .pdf: return .pdf
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .m4a: return .mpeg4Audio
        case .wav: return .wav
        case .aiff: return .aiff
        case .flac: return UTType("org.xiph.flac")
        case .text: return .plainText
        case .rtf: return .rtf
        case .html: return .html
        case .docx: return UTType("org.openxmlformats.wordprocessingml.document")
        case .odt: return UTType("org.oasis-open.opendocument.text")
        case .json: return .json
        case .plist: return .propertyList
        case .csv: return .commaSeparatedText
        case .zip: return .zip
        case .unzipped: return nil
        }
    }
}

/// Turns a file into another format, with what macOS has built in: ImageIO for pictures, PDFKit,
/// the text system for documents, AVFoundation and `afconvert` for movies and sound, and `ditto`
/// for zips. Anything at all can at least be zipped.
enum Converter {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// What a file is, as far as converting it goes.
    enum Kind {
        case folder, archive, pdf, image, video, audio, json, plist, csv, document, other
    }

    static func kind(of url: URL) -> Kind {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .rtfd) { return .document }
        if values?.isDirectory == true { return .folder }
        if type.conforms(to: .zip) { return .archive }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        // (Sound before movies: an .m4a is an MPEG-4 too.)
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .json) { return .json }
        if type.conforms(to: .propertyList) { return .plist }
        if type.conforms(to: .commaSeparatedText) { return .csv }
        if documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        return .other
    }

    /// The text system reads all of these (and Markdown, which is plain text too).
    private static let documentTypes: [UTType] = [.plainText, .rtf, .html, .webArchive]
        + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text"]
            .compactMap { UTType($0) }

    /// What `url` can be turned into, likeliest first, leaving out the format it's in.
    static func formats(for url: URL) -> [FileFormat] {
        let formats: [FileFormat]
        switch kind(of: url) {
        case .folder: formats = [.zip]
        case .archive: formats = [.unzipped]
        case .pdf: formats = [.png, .jpeg, .tiff, .text, .docx, .rtf, .html, .zip]
        case .image: formats = [.png, .jpeg, .pdf, .heic, .tiff, .gif, .bmp, .zip].filter { $0 != .heic || canWriteHEIC }
        case .video: formats = [.mp4, .mov, .gif, .m4a, .zip]
        case .audio: formats = [.m4a, .wav, .aiff, .flac, .zip]
        case .json: formats = [.plist, .csv, .zip]
        case .plist: formats = [.json, .zip]
        case .csv: formats = [.json, .zip]
        case .document: formats = [.pdf, .docx, .rtf, .html, .text, .odt, .zip]
        case .other: formats = [.zip]
        }
        let own = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return formats.filter { $0.type == nil || $0.type != own }
    }

    private static let canWriteHEIC = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)

    /// Turns `url` into `format`, named like it, beside it (or in Oyl's own folder, if its folder
    /// can't be written to). Made aside first, so a half-made file is never left there. Returns
    /// where the new one is.
    static func convert(_ url: URL, to format: FileFormat) async throws -> URL {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("Oyl \(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }
        let made = try await make(url, as: format, in: work)
        return try place(made, beside: url)
    }

    /// Where what can't go beside its original goes.
    static var ownFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Oyl/Converted", isDirectory: true)
    }

    private static func make(_ url: URL, as format: FileFormat, in work: URL) async throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let output = work.appendingPathComponent(format.fileExtension.map { "\(base).\($0)" } ?? base)
        let kind = kind(of: url)
        switch format {
        case .zip:
            // Named as Finder names them: a file keeps its extension inside ("photo.png.zip").
            let zipped = work.appendingPathComponent("\(url.lastPathComponent).zip")
            try await run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, zipped.path])
            return zipped
        case .unzipped:
            return try await unzip(url, named: base, in: work)
        default:
            break
        }
        switch kind {
        case .image:
            if format == .pdf { try pdf(fromImage: url, to: output) } else { try image(url, to: format, at: output) }
        case .pdf:
            if [.png, .jpeg, .tiff].contains(format) { return try pages(of: url, as: format, named: base, in: work) }
            try await document(url, kind: kind, to: format, at: output)
        case .document:
            try await document(url, kind: kind, to: format, at: output)
        case .video:
            try await video(url, to: format, at: output)
        case .audio:
            try await audio(url, to: format, at: output)
        case .json, .plist, .csv:
            try data(url, kind: kind, to: format, at: output)
        case .folder, .archive, .other:
            throw Failure(reason: "Can't make that into \(format.name)")
        }
        return output
    }

    /// Moves a made file in beside the original, under a name not taken yet, or failing that into
    /// Oyl's own folder.
    private static func place(_ made: URL, beside original: URL) throws -> URL {
        let files = FileManager.default
        for folder in [original.deletingLastPathComponent(), ownFolder] {
            do {
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = unused(made.lastPathComponent, in: folder)
                try files.moveItem(at: made, to: target)
                return target
            } catch {
                continue
            }
        }
        throw Failure(reason: "Couldn't save it anywhere")
    }

    /// "Name.ext", or "Name 2.ext", and so on, whichever's free.
    private static func unused(_ name: String, in folder: URL) -> URL {
        let files = FileManager.default
        let first = folder.appendingPathComponent(name)
        guard files.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        for number in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !files.fileExists(atPath: candidate.path) { return candidate }
        }
        return first
    }

    // MARK: Pictures

    /// Re-encoded the right way up, without the original's metadata (where it was taken, and so
    /// on). JPEG and BMP have no transparency, so a window's shadow goes onto white, not black.
    private static func image(_ url: URL, to format: FileFormat, at output: URL) throws {
        guard let type = format.type else { throw Failure(reason: "Can't make that into \(format.name)") }
        var picture = try upright(url)
        if format == .jpeg || format == .bmp { picture = try flattened(picture.image).map { (image: $0, dpi: picture.dpi) } ?? picture }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure(reason: "This Mac can't write \(format.name)")
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9,
                                           kCGImagePropertyDPIWidth: picture.dpi, kCGImagePropertyDPIHeight: picture.dpi]
        CGImageDestinationAddImage(destination, picture.image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(reason: "Couldn't write the \(format.name)") }
    }

    /// The picture's first frame, turned upright, and its resolution. What ImageIO can't read (an
    /// SVG, say), AppKit draws.
    private static func upright(_ url: URL) throws -> (image: CGImage, dpi: Double) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1)]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return (image, properties[kCGImagePropertyDPIWidth] as? Double ?? 72)
            }
        }
        guard let drawn = NSImage(contentsOf: url) else { throw Failure(reason: "Couldn't read the picture") }
        var rect = NSRect(origin: .zero, size: drawn.size)
        guard let image = drawn.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw Failure(reason: "Couldn't read the picture")
        }
        return (image, 72 * Double(image.width) / max(Double(drawn.size.width), 1))
    }

    /// On white, if it has any transparency; nil if it hasn't.
    private static func flattened(_ image: CGImage) throws -> CGImage? {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else { return nil }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// One page the picture's size (in points, so a Retina screenshot's page isn't twice as big).
    private static func pdf(fromImage url: URL, to output: URL) throws {
        let picture = try upright(url)
        let points = NSSize(width: CGFloat(picture.image.width) * 72 / picture.dpi, height: CGFloat(picture.image.height) * 72 / picture.dpi)
        guard let page = PDFPage(image: NSImage(cgImage: picture.image, size: points)) else {
            throw Failure(reason: "Couldn't make the page")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: output) else { throw Failure(reason: "Couldn't write the PDF") }
    }

    /// A PDF's pages as pictures, at twice their size: a TIFF holds them all; PNGs and JPEGs go
    /// one a page, in a folder, unless there's just the one.
    private static func pages(of url: URL, as format: FileFormat, named base: String, in work: URL) throws -> URL {
        guard let document = PDFDocument(url: url), document.pageCount > 0, let type = format.type, let ext = format.fileExtension else {
            throw Failure(reason: "Couldn't read the PDF")
        }
        func render(_ index: Int) throws -> CGImage {
            guard let page = document.page(at: index) else { throw Failure(reason: "Couldn't read page \(index + 1)") }
            let bounds = page.bounds(for: .mediaBox)
            let turned = page.rotation % 180 != 0
            let size = NSSize(width: (turned ? bounds.height : bounds.width) * 2, height: (turned ? bounds.width : bounds.height) * 2)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            var rect = NSRect(origin: .zero, size: size)
            guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw Failure(reason: "Couldn't draw page \(index + 1)")
            }
            return try flattened(image) ?? image
        }
        func write(_ indices: [Int], to output: URL) throws {
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, indices.count, nil) else {
                throw Failure(reason: "This Mac can't write \(format.name)")
            }
            let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9,
                                               kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
            for index in indices { CGImageDestinationAddImage(destination, try render(index), properties as CFDictionary) }
            guard CGImageDestinationFinalize(destination) else { throw Failure(reason: "Couldn't write the \(format.name)") }
        }
        let all = Array(0..<document.pageCount)
        if format == .tiff || all.count == 1 {
            let output = work.appendingPathComponent("\(base).\(ext)")
            try write(all, to: output)
            return output
        }
        let folder = work.appendingPathComponent("\(base) (\(format.name))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in all { try write([index], to: folder.appendingPathComponent("\(base) \(index + 1).\(ext)")) }
        return folder
    }

    // MARK: Documents

    /// Through the text system, which reads and writes Word, OpenDocument, RTF and HTML, and
    /// prints to PDF. (It wants the main thread for HTML, so it all goes there.)
    @MainActor
    private static func document(_ url: URL, kind: Kind, to format: FileFormat, at output: URL) throws {
        let text = try read(url, kind: kind)
        switch format {
        case .text:
            try text.string.write(to: output, atomically: true, encoding: .utf8)
        case .pdf:
            try printed(text, to: output)
        case .rtf, .html, .docx, .odt:
            let types: [FileFormat: NSAttributedString.DocumentType] = [.rtf: .rtf, .html: .html, .docx: .officeOpenXML, .odt: .openDocument]
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: types[format]!])
            try data.write(to: output)
        default:
            throw Failure(reason: "Can't make that into \(format.name)")
        }
    }

    @MainActor
    private static func read(_ url: URL, kind: Kind) throws -> NSAttributedString {
        if kind == .pdf {
            guard let text = PDFDocument(url: url)?.selectionForEntireDocument?.attributedString else {
                throw Failure(reason: "There's no text in it")
            }
            return text
        }
        if ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) {
            return markdown(try String(contentsOf: url, encoding: .utf8))
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    /// Markdown as rich text: headings bigger and bold, emphasis, code in a fixed face, links, and
    /// a bullet or number on each list item. (Foundation parses it, but leaves the blocks run
    /// together and unstyled.)
    private static func markdown(_ source: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        let out = NSMutableAttributedString()
        let spacing = NSMutableParagraphStyle()
        spacing.paragraphSpacing = 8
        var block: Int?
        for run in parsed.runs {
            let intent = run.presentationIntent?.components ?? []
            var size: CGFloat = 12, bold = false, fixed = false, prefix = ""
            for component in intent {
                switch component.kind {
                case .header(let level):
                    size = [24, 20, 16, 14, 13, 12][min(max(level, 1), 6) - 1]
                    bold = true
                case .codeBlock:
                    fixed = true
                case .listItem(let ordinal):
                    let ordered = intent.contains { if case .orderedList = $0.kind { return true } else { return false } }
                    prefix = ordered ? "\(ordinal). " : "• "
                default:
                    break
                }
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { bold = true }
                if inline.contains(.code) { fixed = true }
            }
            let identity = intent.first?.identity
            if identity != block {
                if block != nil { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: spacing])) }
                if !prefix.isEmpty {
                    out.append(NSAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: spacing]))
                }
                block = identity
            }
            var font = fixed ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: bold ? .bold : .regular)
                : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            if run.inlinePresentationIntent?.contains(.emphasized) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: spacing]
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    /// Printed to a PDF on US Letter with three-quarter-inch margins, black on white whatever the
    /// Mac's look.
    @MainActor
    private static func printed(_ text: NSAttributedString, to output: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        for side in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: side] = 54 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 108, height: 10))
        view.appearance = NSAppearance(named: .aqua)
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: output.path) else { throw Failure(reason: "Couldn't print it") }
    }

    // MARK: Movies and sound

    /// Rewrapped as it is if it can be (quick, and nothing lost), else re-encoded; or its sound
    /// alone; or a GIF.
    private static func video(_ url: URL, to format: FileFormat, at output: URL) async throws {
        let asset = AVURLAsset(url: url)
        let type: AVFileType
        switch format {
        case .gif: return try await gif(from: asset, to: output)
        case .mp4: type = .mp4
        case .mov: type = .mov
        case .m4a: type = .m4a
        default: throw Failure(reason: "Can't make that into \(format.name)")
        }
        if format == .m4a, try await asset.loadTracks(withMediaType: .audio).isEmpty {
            throw Failure(reason: "There's no sound in it")
        }
        let presets = format == .m4a ? [AVAssetExportPresetAppleM4A] : [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var problem: Error?
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset), session.supportedFileTypes.contains(type) else { continue }
            try? FileManager.default.removeItem(at: output)
            session.outputURL = output
            session.outputFileType = type
            await session.export()
            if session.status == .completed { return }
            problem = session.error
        }
        throw problem ?? Failure(reason: "Couldn't make it into \(format.name)")
    }

    /// Twelve frames a second, 640 points across at most, the first 30 seconds, looping.
    private static func gif(from asset: AVURLAsset, to output: URL) async throws {
        let seconds = min(try await asset.load(.duration).seconds, 30)
        let rate = 12.0
        let count = max(Int(seconds * rate), 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(value: 1, timescale: 48)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw Failure(reason: "Couldn't start the GIF")
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / rate]]
        for index in 0..<count {
            let image = try await generator.image(at: CMTime(seconds: Double(index) / rate, preferredTimescale: 600)).image
            CGImageDestinationAddImage(destination, image, delay as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure(reason: "Couldn't write the GIF") }
    }

    /// With `afconvert`: AAC at its best variable rate, 16-bit WAV or AIFF, or FLAC.
    private static func audio(_ url: URL, to format: FileFormat, at output: URL) async throws {
        let arguments: [String]
        switch format {
        case .m4a: arguments = ["-f", "m4af", "-d", "aac", "-s", "3", "-q", "127"]
        case .wav: arguments = ["-f", "WAVE", "-d", "LEI16"]
        case .aiff: arguments = ["-f", "AIFF", "-d", "BEI16"]
        case .flac: arguments = ["-f", "flac", "-d", "flac"]
        default: throw Failure(reason: "Can't make that into \(format.name)")
        }
        try await run("/usr/bin/afconvert", arguments + [url.path, output.path])
    }

    // MARK: Data

    private static func data(_ url: URL, kind: Kind, to format: FileFormat, at output: URL) throws {
        let input = try Data(contentsOf: url)
        let value: Any
        switch kind {
        case .json: value = try JSONSerialization.jsonObject(with: input, options: [.fragmentsAllowed])
        case .plist: value = try PropertyListSerialization.propertyList(from: input, format: nil)
        default: value = try records(fromCSV: String(decoding: input, as: UTF8.self))
        }
        let written: Data
        switch format {
        case .json:
            written = try JSONSerialization.data(withJSONObject: jsonSafe(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        case .plist:
            written = try PropertyListSerialization.data(fromPropertyList: plistSafe(value), format: .xml, options: 0)
        case .csv:
            guard let rows = value as? [[String: Any]] else { throw Failure(reason: "Only a list of records makes a CSV") }
            written = Data(csv(rows).utf8)
        default:
            throw Failure(reason: "Can't make that into \(format.name)")
        }
        try written.write(to: output)
    }

    /// Dates as ISO 8601 and data as Base64, which JSON hasn't got.
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(jsonSafe)
        case let array as [Any]: return array.map(jsonSafe)
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let data as Data: return data.base64EncodedString()
        default: return value
        }
    }

    /// Nulls as empty strings, which a property list hasn't got.
    private static func plistSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(plistSafe)
        case let array as [Any]: return array.map(plistSafe)
        case is NSNull: return ""
        default: return value
        }
    }

    /// The first row names the columns.
    private static func records(fromCSV text: String) throws -> [[String: Any]] {
        let rows = csvRows(text)
        guard let header = rows.first, !header.isEmpty else { throw Failure(reason: "The CSV is empty") }
        return rows.dropFirst().filter { $0 != [""] }.map { row in
            var record: [String: Any] = [:]
            for (index, name) in header.enumerated() { record[name] = index < row.count ? row[index] : "" }
            return record
        }
    }

    /// Fields split on commas, quoted ones kept whole ("" for a quote inside).
    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))[...]
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" { field.append("\""); characters.removeFirst() } else { quoted = false }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// The columns in the order they first come up.
    private static func csv(_ rows: [[String: Any]]) -> String {
        var columns: [String] = []
        for row in rows {
            for key in row.keys.sorted() where !columns.contains(key) { columns.append(key) }
        }
        func cell(_ value: Any?) -> String {
            let text: String
            switch value {
            case nil, is NSNull: text = ""
            case let string as String: text = string
            case let other?:
                if JSONSerialization.isValidJSONObject(other), let data = try? JSONSerialization.data(withJSONObject: other) {
                    text = String(decoding: data, as: UTF8.self)
                } else {
                    text = "\(other)"
                }
            }
            return text.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        return ([columns.map(cell).joined(separator: ",")] + rows.map { row in columns.map { cell(row[$0]) }.joined(separator: ",") })
            .joined(separator: "\n") + "\n"
    }

    // MARK: Archives

    /// Into a folder named after the zip, unless everything in it is in one folder already.
    private static func unzip(_ url: URL, named base: String, in work: URL) async throws -> URL {
        let files = FileManager.default
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try await run("/usr/bin/ditto", ["-x", "-k", url.path, unpacked.path])
        let inside = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        if inside.count == 1 { return inside[0] }
        let folder = work.appendingPathComponent(base, isDirectory: true)
        try files.moveItem(at: unpacked, to: folder)
        return folder
    }

    /// Runs a command-line tool to the end; its complaint, if it fails, is the failure's reason.
    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let complaint = Pipe()
            process.standardError = complaint
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let said = String(decoding: complaint.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(reason: said.isEmpty ? "Couldn't convert it" : String(said.prefix(120))))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
