import SwiftUI

/// A song's time-synced lyrics.
struct Lyrics: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        let time: Double  // seconds into the song
        let text: String
    }

    let trackID: String
    let lines: [Line]

    /// From LRCLIB, a free, open database of synced lyrics. It's sent the song's title, artist,
    /// album and length; nil when it doesn't have the song (or it has only unsynced lyrics).
    static func fetch(_ track: Track) async -> Lyrics? {
        let fields = [("track_name", track.title), ("artist_name", track.artist), ("album_name", track.album),
                      ("duration", String(Int(track.duration.rounded())))]
        if let lines = await lines(from: "https://lrclib.net/api/get", fields) {
            return Lyrics(trackID: track.id, lines: lines)
        }
        // Without an exact match (album names differ between services), search by title and
        // artist and take the first synced result of about the same length.
        guard let results = await json(from: "https://lrclib.net/api/search", Array(fields.prefix(2))) as? [[String: Any]]
        else { return nil }
        for result in results {
            guard let synced = result["syncedLyrics"] as? String,
                  abs((result["duration"] as? Double ?? 0) - track.duration) < 3 else { continue }
            let lines = parse(synced)
            if !lines.isEmpty { return Lyrics(trackID: track.id, lines: lines) }
        }
        return nil
    }

    private static func lines(from url: String, _ fields: [(String, String)]) async -> [Line]? {
        guard let synced = (await json(from: url, fields) as? [String: Any])?["syncedLyrics"] as? String else { return nil }
        let lines = parse(synced)
        return lines.isEmpty ? nil : lines
    }

    private static func json(from url: String, _ fields: [(String, String)]) async -> Any? {
        guard var components = URLComponents(string: url) else { return nil }
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let address = components.url else { return nil }
        var request = URLRequest(url: address, timeoutInterval: 8)
        request.setValue("Oyl (a macOS notch app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
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
    func toggleLyrics() {
        guard nowPlaying.lyrics != nil else { return }
        withAnimation(NotchView.open) {
            if page == .music {
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
