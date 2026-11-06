import Foundation
import FoundationModels

/// The log's stories, written by Apple's on-device model where Apple Intelligence is on: a month
/// of a project's days as one paragraph, each step leading to the next, and the story of the
/// whole project from its months. Only from what you wrote, keeping its names and numbers.
/// Nothing leaves the Mac.
@available(macOS 26, *)
struct LogWriter: LogWriting {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// About 1,700 tokens of notes, leaving room in the model's 4,096 for its instructions and
    /// what it writes.
    var budget: Int { 6000 }

    static let chapterInstructions = """
        You keep a work log for one person, written from their own notes. You're given one \
        project's notes for one month, day by day, and sometimes a paragraph already written \
        about that month's earlier days. Write one paragraph of 2 to 5 sentences that tells \
        that month's work as one connected story. Don't retell each note: group the small \
        steps into the larger pieces of work they were part of, and say how one led to the \
        next (then, after that, which let me, so that). Put the results and numbers first. If \
        there's a paragraph already, write a new one that covers the earlier days too. Use \
        only what the notes say. Never add results, numbers, names, reasons, feelings or \
        descriptions of the project that aren't in them. Keep the names, numbers and tools \
        the notes use. Write in the first person, in the past tense, plainly. No heading, no \
        list, no quotes, no dates. Reply with the paragraph only.
        """

    static let storyInstructions = """
        You keep a work log for one person, written from their own notes. You're given what \
        they did on one project, month by month, and sometimes the story of the project \
        already written from its earlier months. Write the big picture in 2 to 4 sentences: \
        the arc of the work from start to now, its main milestones and results, each \
        connected to the last. Don't retell every step, and don't say what the project is \
        unless what you're given says. If there's a story already, write a new one that covers \
        it and the newer months. Use only what you're given. Never add results, numbers, \
        names or reasons that aren't in it. Keep the names, numbers and tools it uses. Write \
        in the first person, in the past tense, plainly. No heading, no list, no quotes. \
        Reply with the story only.
        """

    func chapter(project: String, month: String, days: [String], earlier: String?) async -> String? {
        var prompt = "Project: \(project)\nMonth: \(month)\n"
        if let earlier { prompt += "Already written about this month's earlier days: \(earlier)\n" }
        prompt += "Notes:\n" + days.joined(separator: "\n")
        return await write(prompt, instructions: Self.chapterInstructions, most: 320)
    }

    func story(project: String, chapters: [String], earlier: String?) async -> String? {
        var prompt = "Project: \(project)\n"
        if let earlier { prompt += "The story so far, from its earlier months: \(earlier)\n" }
        prompt += "Month by month:\n" + chapters.joined(separator: "\n")
        return await write(prompt, instructions: Self.storyInstructions, most: 300)
    }

    private func write(_ prompt: String, instructions: String, most: Int) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: most))
            return Self.tidy(response.content)
        } catch {
            // (Not what it was about: that's yours.)
            WorkLog.log.error("Couldn't write a story: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// The paragraph alone: no heading or "Here's…" before it, no quotes or bold round it.
    static func tidy(_ text: String) -> String? {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count > 1, let first = lines.first, first.hasSuffix(":") || first.lowercased().hasPrefix("here") || first.hasPrefix("#") {
            lines.removeFirst()
        }
        var paragraph = lines.joined(separator: " ").replacingOccurrences(of: "**", with: "")
        paragraph = paragraph.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ").union(.whitespaces))
        return paragraph.isEmpty ? nil : paragraph
    }
}
