import AVFoundation
import FoundationModels
import ImageIO
import Vision

/// Labels for screenshots and screen recordings, made on the Mac from what's in them: the text in
/// the picture (or a recording's first moments), read with Vision, put into a few words by Apple's
/// on-device model where Apple Intelligence is on, or else the picture's most prominent line, or
/// what Vision sees in it. Nothing leaves the Mac.
enum ScreenshotLabeler {
    struct Line {
        let text: String
        /// Vision's: 0...1, from the bottom left.
        let box: CGRect
        let confidence: Float
    }

    /// The longest a label gets, in characters.
    static let longest = 48

    /// A label for the file, or nil if there's nothing in it to go by.
    static func label(for url: URL, movie: Bool) async -> String? {
        guard let image = movie ? await frame(of: url) : picture(at: url) else { return nil }
        let lines = read(image)
        let text = digest(lines)
        if !text.isEmpty, let named = await name(text) { return named }
        return prominent(lines) ?? classify(image)
    }

    // MARK: Looking

    /// Big enough to read small type in, not so big it's slow.
    private static func picture(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A second in, once it's under way (or the first frame of a shorter one).
    private static func frame(of url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2600, height: 2600)
        let length = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let at = CMTime(seconds: min(1, max(length / 2, 0)), preferredTimescale: 600)
        return try? await generator.image(at: at).image
    }

    static func read(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Line(text: text, box: observation.boundingBox, confidence: best.confidence)
        }
    }

    /// What Vision makes of a picture with no words in it: its likeliest subject.
    private static func classify(_ image: CGImage) -> String? {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let generic: Set<String> = ["screenshot", "document", "text", "structure", "material", "art", "illustrations", "graphic"]
        guard let seen = (request.results ?? []).first(where: { $0.confidence > 0.15 && !generic.contains($0.identifier) }) else { return nil }
        let words = seen.identifier.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Naming

    /// The lines worth reading: sure enough, wordy enough, not the menu bar; the biggest few,
    /// top to bottom.
    static func digest(_ lines: [Line]) -> String {
        let kept = lines.filter(worthReading)
            .sorted { $0.box.height > $1.box.height }
            .prefix(30)
            .sorted { abs($0.box.maxY - $1.box.maxY) > 0.01 ? $0.box.maxY > $1.box.maxY : $0.box.minX < $1.box.minX }
        var text = ""
        for line in kept where text.count + line.text.count < 1500 { text += line.text + "\n" }
        return text
    }

    private static func worthReading(_ line: Line) -> Bool {
        line.confidence >= 0.4 && line.text.filter(\.isLetter).count >= 2 && line.box.minY < 0.975
    }

    /// The biggest line, high up counting for more: likeliest to be a title.
    static func prominent(_ lines: [Line]) -> String? {
        let menus: Set<String> = ["File", "Edit", "View", "Window", "Help", "Go", "History", "Bookmarks", "Format", "Tools"]
        let best = lines
            .filter { worthReading($0) && $0.text.count >= 3 && !menus.contains($0.text) && $0.text.filter(\.isLetter).count * 2 >= $0.text.count }
            .max { $0.box.height * (0.7 + 0.3 * $0.box.maxY) < $1.box.height * (0.7 + 0.3 * $1.box.maxY) }
        return best.flatMap { tidy($0.text) }
    }

    private static func name(_ text: String) async -> String? {
        guard #available(macOS 26, *) else { return nil }
        return await OnDeviceNamer.name(text)
    }

    /// One line, without quotes, a "Label:" or a full stop, its first letter capital, cut at a word
    /// to fit; nil for nothing, or what reads as the model declining.
    static func tidy(_ said: String) -> String? {
        var label = said.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if let colon = label.range(of: "label:", options: [.caseInsensitive, .anchored]) { label.removeSubrange(colon) }
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’*`.").union(.whitespaces))
        for word in [" screenshot", " screen shot"] where label.lowercased().hasSuffix(word) { label.removeLast(word.count) }
        let lowered = label.lowercased()
        guard label.count >= 2, !["sorry", "i can't", "i cannot", "unable to", "as an ai"].contains(where: lowered.contains) else { return nil }
        if label.count > longest {
            let cut = label.prefix(longest)
            label = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
            label += "…"
        }
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

/// Apple's on-device model, asked for a few words for what a screenshot's text is of.
@available(macOS 26, *)
private enum OnDeviceNamer {
    static let instructions = """
        You name screenshots. You're given the text found in one, in reading order. Reply with a \
        label for it of 3 to 7 words, the way a person would name the file: what it is and what \
        it's about, keeping the names, places, titles and numbers that make it this one and not \
        another. Never use the word screenshot. No quotes, no dates or times, no punctuation at \
        the end. Reply with the label only.
        Examples:
        "Your order has shipped / Order #1182 / Wireless keyboard" -> Wireless keyboard order shipped
        "Sam Rivera / Can you send the slides? / Sure, after lunch" -> Sam asking for the slides
        "README.md / ## Installing / brew install tod" -> README install instructions
        """

    static func name(_ text: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: "Text in the screenshot:\n" + text,
                                                     options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 24))
            return ScreenshotLabeler.tidy(response.content)
        } catch {
            return nil
        }
    }
}
