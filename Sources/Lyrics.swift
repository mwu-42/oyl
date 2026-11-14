import SwiftUI

/// A song's time-synced lyrics.
struct Lyrics: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        let time: Double  // seconds into the song
        let text: String
    }

    let trackID: String
    let lines: [Line]

    /// What looking a song up came to: its lyrics, none (LRCLIB doesn't have them, synced, yet),
    /// or no answer at all (offline, or LRCLIB down), which isn't taken for none.
    enum Lookup: Equatable, Sendable {
        case found(Lyrics)
        case none
        case failed
    }

    /// From LRCLIB, a free, open database of synced lyrics people add to (so a song just out
    /// often isn't in it yet). It's sent the song's title, artist, album and length; then, without
    /// an exact match (album names differ between services), it's searched by title and artist;
    /// then by the title without what services add to it ("(feat. …)", " - Remastered 2011").
    static func fetch(_ track: Track) async -> Lookup {
        let fields = [("track_name", track.title), ("artist_name", track.artist), ("album_name", track.album),
                      ("duration", String(Int(track.duration.rounded())))]
        var answered = false
        switch await json(from: "https://lrclib.net/api/get", fields) {
        case .some(let found):
            answered = true
            if let synced = (found as? [String: Any])?["syncedLyrics"] as? String, !parse(synced).isEmpty {
                return .found(Lyrics(trackID: track.id, lines: parse(synced)))
            }
        case .none(let missing):
            answered = answered || missing
        }
        for title in Set([track.title, plainTitle(track.title)]).sorted(by: { $0.count > $1.count }) {
            switch await json(from: "https://lrclib.net/api/search", [("track_name", title), ("artist_name", track.artist)]) {
            case .some(let found):
                answered = true
                if let lines = closest(found as? [[String: Any]] ?? [], to: track.duration) {
                    return .found(Lyrics(trackID: track.id, lines: lines))
                }
            case .none(let missing):
                answered = answered || missing
            }
        }
        return answered ? .none : .failed
    }

    /// The first synced result of about the same length (within 3 seconds).
    private static func closest(_ results: [[String: Any]], to duration: Double) -> [Line]? {
        for result in results {
            guard let synced = result["syncedLyrics"] as? String,
                  abs((result["duration"] as? Double ?? 0) - duration) < 3 else { continue }
            let lines = parse(synced)
            if !lines.isEmpty { return lines }
        }
        return nil
    }

    /// A title without what services add to it: a featured artist ("(feat. X)", "[with X]"),
    /// or a version ("- Remastered 2011", "(Radio Edit)", "- From the Motion Picture …").
    static func plainTitle(_ title: String) -> String {
        let ns = title as NSString
        var plain = extras.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        if let dash = plain.range(of: " - ") { plain = String(plain[..<dash.lowerBound]) }
        plain = plain.trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? title : plain
    }

    private static let extras = try! NSRegularExpression(
        pattern: #"\s*[\(\[](?:feat\.?|ft\.?|featuring|with|prod\.?|from|remaster(?:ed)?|\d{4} remaster(?:ed)?|radio edit|edit|single version|album version|explicit|clean|live|acoustic|mono|stereo|bonus track|sped up|slowed)\b[^\)\]]*[\)\]]"#,
        options: [.caseInsensitive])

    /// What LRCLIB said (`.some`), or nothing: `.none(true)` when it said it hasn't the song
    /// (404), `.none(false)` when it couldn't be asked.
    private enum Answer {
        case some(Any)
        case none(Bool)
    }

    private static func json(from url: String, _ fields: [(String, String)]) async -> Answer {
        guard var components = URLComponents(string: url) else { return .none(false) }
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let address = components.url else { return .none(false) }
        var request = URLRequest(url: address, timeoutInterval: 10)
        request.setValue("Oyl (a macOS notch app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .none(false) }
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) else { return .none(status == 404) }
        return .some(object)
    }

    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)

    /// LRC: each line starts with one or more [mm:ss.xx] stamps.
    static func parse(_ text: String) -> [Line] {
        var lines: [Line] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw), source = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: source.length))
            guard let last = matches.last else { continue }
            let words = source.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(source.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(source.substring(with: match.range(at: 2))) ?? 0
                lines.append(Line(time: minutes * 60 + seconds, text: words.isEmpty ? "♪" : words))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}

extension NotchState {
    /// Shows or hides the lyrics under the song, if it has any; from elsewhere, goes to the song.
    /// In Midnight Oyl, where they float in the sky over any page, it stays where it is.
    func toggleLyrics() {
        guard nowPlaying.lyrics != nil else { return }
        withAnimation(NotchView.open) {
            if page == .music || theme == .midnight {
                showsLyrics.toggle()
            } else {
                page = .music
                showsLyrics = true
            }
        }
    }
}

/// Three lines, the way Spotify shows lyrics: the one before, the one being sung, the one next.
struct LyricsView: View {
    let lyrics: Lyrics
    @ObservedObject var nowPlaying: NowPlaying
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            // A touch early, so a line is up as it's sung rather than just after.
            let position = nowPlaying.position(at: context.date) + 0.25
            let index = lyrics.lines.lastIndex { $0.time <= position } ?? -1
            VStack(alignment: .leading, spacing: 3) {
                line(index - 1, size: 12, opacity: 0.4)
                line(index, size: 14.5, opacity: 1)
                line(index + 1, size: 12, opacity: 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(index)
            .transition(.push(from: .bottom))
            .animation(.easeInOut(duration: 0.35), value: index)
        }
        .padding(.horizontal, 14)
        .frame(height: Layout.lyricsHeight - 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.tint(Color(nsColor: nowPlaying.accent)).opacity(0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func line(_ index: Int, size: CGFloat, opacity: Double) -> some View {
        let text = lyrics.lines.indices.contains(index) ? lyrics.lines[index].text : " "
        return Text(text)
            // Bold at its size, but a line to be read, not a label.
            .notchFont(size: size, weight: .bold, role: .heading)
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
    }
}
