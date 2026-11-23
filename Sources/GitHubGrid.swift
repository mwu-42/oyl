import AppKit
import SwiftUI

/// Your GitHub contributions over the last year: the grid on your profile, a square for each day
/// and a week to a column, brighter the more you did that day (commits, pull requests, issues and
/// reviews, as GitHub counts them, private ones included). Read from GitHub with its own
/// command-line tool, `gh`, as it's signed in, so Oyl keeps no sign-in of its own. It's read when
/// the Activity page opens (if it's been ten minutes), and every ten minutes while it's open. The
/// last grid read is kept across launches, so it's there at once.
@MainActor
final class GitHubContributions: ObservableObject {
    struct Day: Equatable, Codable {
        /// As GitHub dates it: "2026-11-23".
        var date: String
        /// 0 is Sunday.
        var weekday: Int
        var count: Int
        /// 0 for none, then which of GitHub's quartiles the day's in, 1 to 4.
        var level: Int
    }

    struct Grid: Equatable, Codable {
        var login: String
        var total: Int
        /// Oldest first, each Sunday to Saturday (the first and last can be short).
        var weeks: [[Day]]
        var read: Date
    }

    enum Trouble: Error, Equatable {
        /// No `gh` where Homebrew (or the like) puts it.
        case noTool
        /// `gh` isn't signed in.
        case signedOut
        /// GitHub couldn't be reached, or said something unexpected.
        case failed
    }

    static let shared = GitHubContributions()

    /// The last read, if there's been one.
    @Published private(set) var grid: Grid?
    /// Why the last read didn't come back, if it didn't.
    @Published private(set) var trouble: Trouble?
    @Published private(set) var isReading = false

    nonisolated static let interval: TimeInterval = 600
    private let defaults: UserDefaults
    private var timer: Timer?
    private static let key = "github.contributions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        grid = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Grid.self, from: $0) }
    }

    /// The page is up: read now if it's been a while, and every ten minutes after.
    func start() {
        guard Feature.githubGrid.isOn, timer == nil else { return }
        if grid.map({ Date().timeIntervalSince($0.read) > Self.interval }) ?? true { read() }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func read() {
        guard !isReading else { return }
        isReading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetch(tool: Self.tool())
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.take(result) }
            }
        }
    }

    /// What a read came back with: a new grid is kept; trouble is noted, the last grid still shown.
    func take(_ result: Result<Grid, Trouble>) {
        isReading = false
        switch result {
        case .success(let read):
            trouble = nil
            if read != grid { grid = read }
            if let data = try? JSONEncoder().encode(read) { defaults.set(data, forKey: Self.key) }
        case .failure(let reason):
            if trouble != reason { trouble = reason }
        }
    }

    // MARK: Reading

    /// Who's signed in, and their calendar for the year to today.
    nonisolated static let query = "query { viewer { login contributionsCollection { contributionCalendar { totalContributions "
        + "weeks { contributionDays { date weekday contributionCount contributionLevel } } } } } }"

    /// Where `gh` is: an app isn't given the shell's PATH, so in the places it's installed to.
    nonisolated static func tool(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let places = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh", "/usr/bin/gh",
                      home.appendingPathComponent(".local/bin/gh").path, home.appendingPathComponent("bin/gh").path]
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Asks GitHub, through `tool`, given up on after `patience` seconds. Off the main thread.
    nonisolated static func fetch(tool: URL?, patience: TimeInterval = 30) -> Result<Grid, Trouble> {
        guard let tool else { return .failure(.noTool) }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["api", "graphql", "-f", "query=\(query)"]
        var environment = ProcessInfo.processInfo.environment
        // No asking, no update notices, no colors: just the answer.
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_SPINNER_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe(), complaint = Pipe()
        process.standardOutput = output
        process.standardError = complaint
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.failed)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + patience, execute: watchdog)
        // (What it says on the side is a line or two, so it can wait in its pipe till the answer's read.)
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        let said = complaint.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            let words = String(decoding: said, as: UTF8.self).lowercased()
            // gh's own code for wanting a sign-in is 4.
            let signedOut = process.terminationStatus == 4 || words.contains("auth login") || words.contains("not logged")
            return .failure(signedOut ? .signedOut : .failed)
        }
        return parse(answer, read: Date()).map { .success($0) } ?? .failure(.failed)
    }

    private struct Reply: Decodable {
        struct Body: Decodable {
            struct Viewer: Decodable {
                struct Collection: Decodable {
                    struct Calendar: Decodable {
                        struct Week: Decodable {
                            struct Day: Decodable {
                                let date: String
                                let weekday: Int
                                let contributionCount: Int
                                let contributionLevel: String
                            }
                            let contributionDays: [Day]
                        }
                        let totalContributions: Int
                        let weeks: [Week]
                    }
                    let contributionCalendar: Calendar
                }
                let login: String
                let contributionsCollection: Collection
            }
            let viewer: Viewer
        }
        let data: Body?
    }

    nonisolated static let levels = ["NONE": 0, "FIRST_QUARTILE": 1, "SECOND_QUARTILE": 2, "THIRD_QUARTILE": 3, "FOURTH_QUARTILE": 4]

    /// GitHub's answer as a grid, or nil if it isn't one.
    nonisolated static func parse(_ data: Data, read: Date) -> Grid? {
        guard let viewer = (try? JSONDecoder().decode(Reply.self, from: data))?.data?.viewer else { return nil }
        let calendar = viewer.contributionsCollection.contributionCalendar
        let weeks = calendar.weeks.map { week in
            week.contributionDays.map { day in
                Day(date: day.date, weekday: day.weekday, count: day.contributionCount,
                    level: levels[day.contributionLevel] ?? (day.contributionCount > 0 ? 1 : 0))
            }
        }
        .filter { !$0.isEmpty }
        guard !weeks.isEmpty else { return nil }
        return Grid(login: viewer.login, total: calendar.totalContributions, weeks: weeks, read: read)
    }

    // MARK: Showing

    /// Where each month's name goes over the grid: the week it starts in, left out where it'd
    /// crowd the next (as the first month's often would).
    nonisolated static func months(_ weeks: [[Day]], names: [String] = Calendar.current.shortStandaloneMonthSymbols) -> [(week: Int, name: String)] {
        var found: [(week: Int, name: String)] = []
        var last = 0
        for (index, week) in weeks.enumerated() {
            // The month a week's in is its Sunday's (the first week, whatever day it starts on).
            guard let first = week.first, let month = month(of: first.date) else { continue }
            if month != last {
                found.append((index, names.indices.contains(month - 1) ? names[month - 1] : ""))
                last = month
            }
        }
        return found.enumerated().filter { offset, mark in
            offset + 1 >= found.count || found[offset + 1].week - mark.week >= 3
        }
        .map(\.element)
    }

    nonisolated static func month(of date: String) -> Int? {
        let parts = date.split(separator: "-")
        return parts.count == 3 ? Int(parts[1]) : nil
    }

    /// "Nov 12".
    nonisolated static func said(_ date: String, names: [String] = Calendar.current.shortStandaloneMonthSymbols) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]), names.indices.contains(month - 1) else { return date }
        return "\(names[month - 1]) \(day)"
    }
}

/// Where the grid's squares go in a space `size` big, for `weeks` weeks: the months' names in a
/// row over it, then seven rows, Sunday at the top.
struct ContributionLayout {
    static let monthRow: CGFloat = 10
    let pitch: CGFloat
    let cell: CGFloat
    let origin: CGPoint

    init(size: CGSize, weeks: Int) {
        let columns = CGFloat(max(weeks, 1))
        pitch = max(min(size.width / columns, (size.height - Self.monthRow) / 7), 1)
        cell = pitch * 0.8
        // Against the right, where today is.
        origin = CGPoint(x: size.width - columns * pitch, y: Self.monthRow)
    }

    func rect(week: Int, weekday: Int) -> CGRect {
        CGRect(x: origin.x + CGFloat(week) * pitch + (pitch - cell) / 2, y: origin.y + CGFloat(weekday) * pitch + (pitch - cell) / 2,
               width: cell, height: cell)
    }

    func center(week: Int, weekday: Int) -> CGPoint {
        let square = rect(week: week, weekday: weekday)
        return CGPoint(x: square.midX, y: square.midY)
    }

    /// The day at `point`, if there's one there.
    func day(at point: CGPoint, in weeks: [[GitHubContributions.Day]]) -> GitHubContributions.Day? {
        let week = Int(floor((point.x - origin.x) / pitch)), weekday = Int(floor((point.y - origin.y) / pitch))
        guard weeks.indices.contains(week), (0..<7).contains(weekday) else { return nil }
        return weeks[week].first { $0.weekday == weekday }
    }
}

/// On the Activity page, under Claude's rows: the grid, kept up to date while it's showing.
struct GitHubRow: View {
    @ObservedObject var github = GitHubContributions.shared

    var body: some View {
        ContributionsRow(grid: github.grid, trouble: github.trouble, reading: github.isReading)
            .onAppear { github.start() }
            .onDisappear { github.stop() }
    }
}

/// "GitHub" and what's in the grid (the year's total, or the day pointed at), then the grid with
/// the months over it. Click a day for what you did that day, on GitHub.
///
/// In Oyl's look it's GitHub's grid in the page's pink: rounded squares, brighter the busier the
/// day, today ringed in white, the one pointed at ringed brighter. In Midnight Oyl's it's a star
/// chart: each day a star, from a mote of dust for a day with nothing to a four-pointed star for
/// the busiest, the brighter ones twinkling and a run of them in a week joined into a
/// constellation. Today's star is circled, and the one pointed at swells in a pool of moonlight.
struct ContributionsRow: View {
    let grid: GitHubContributions.Grid?
    let trouble: GitHubContributions.Trouble?
    let reading: Bool
    @StateObject private var pointed: LocalState<GitHubContributions.Day?>
    @Environment(\.notchTheme) private var theme
    private var tint: Color { theme.tint(ActivityPage.tint) }

    /// `pointing`: as if pointed at from the first (for pictures of it).
    init(grid: GitHubContributions.Grid?, trouble: GitHubContributions.Trouble?, reading: Bool,
         pointing: GitHubContributions.Day? = nil) {
        self.grid = grid
        self.trouble = trouble
        self.reading = reading
        _pointed = StateObject(wrappedValue: LocalState(pointing))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            figures
                .frame(width: 54, alignment: .leading)
            GeometryReader { geometry in
                let weeks = grid?.weeks ?? Self.blank
                let layout = ContributionLayout(size: geometry.size, weeks: weeks.count)
                ZStack(alignment: .topLeading) {
                    months(weeks, layout)
                    if theme == .midnight {
                        StarChart(weeks: weeks, layout: layout, today: grid != nil ? weeks.last?.last?.date : nil,
                                  pointed: pointed.value?.date)
                    } else {
                        squares(weeks, layout)
                    }
                    if grid == nil { note }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard let grid else { return }
                    switch phase {
                    case .active(let point):
                        let day = layout.day(at: point, in: grid.weeks)
                        if day != pointed.value {
                            withAnimation(theme == .midnight ? .easeInOut(duration: 0.3) : .easeOut(duration: 0.12)) { pointed.value = day }
                        }
                    case .ended:
                        withAnimation(theme == .midnight ? .easeInOut(duration: 0.4) : .easeOut(duration: 0.15)) { pointed.value = nil }
                    }
                }
                .onTapGesture { open() }
            }
        }
        .frame(height: Layout.githubHeight)
        .help(help)
    }

    /// "GitHub", then the year's total or the day pointed at's count, and what it's of.
    private var figures: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("GitHub")
                .notchFont(size: 11, weight: .medium)
                .foregroundStyle(tint.opacity(0.75))
                .frame(height: 16)
            Spacer(minLength: 0)
            if let grid {
                let day = pointed.value
                Text((day?.count ?? grid.total).formatted())
                    .notchFont(size: 11, weight: .medium, digits: true)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(day.map { $0.date == grid.weeks.last?.last?.date ? "today" : "on " + GitHubContributions.said($0.date) } ?? "past year")
                    .notchFont(size: 9.5, weight: .medium)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 2)
    }

    private func months(_ weeks: [[GitHubContributions.Day]], _ layout: ContributionLayout) -> some View {
        ForEach(grid == nil ? [] : GitHubContributions.months(weeks), id: \.week) { mark in
            Text(mark.name)
                .notchFont(size: 8, weight: .medium, role: .label)
                .foregroundStyle(.white.opacity(theme == .midnight ? 0.45 : 0.38))
                .fixedSize()
                .offset(x: layout.rect(week: mark.week, weekday: 0).minX, y: -1)
        }
    }

    /// Oyl's look: rounded squares in the page's pink.
    private func squares(_ weeks: [[GitHubContributions.Day]], _ layout: ContributionLayout) -> some View {
        let today = grid != nil ? weeks.last?.last?.date : nil
        let pointed = pointed.value?.date
        let tint = tint
        return Canvas { context, _ in
            let corner = layout.cell * 0.24
            for (index, week) in weeks.enumerated() {
                for day in week {
                    let square = layout.rect(week: index, weekday: day.weekday)
                    let shape = Path(roundedRect: square, cornerRadius: corner)
                    let fill = day.level == 0 ? Color.white.opacity(0.08) : tint.opacity([0.3, 0.5, 0.75, 1][min(day.level, 4) - 1])
                    context.fill(shape, with: .color(fill))
                    if day.date == pointed {
                        context.stroke(Path(roundedRect: square.insetBy(dx: -0.6, dy: -0.6), cornerRadius: corner + 0.6),
                                       with: .color(.white), lineWidth: 1.1)
                    } else if day.date == today {
                        context.stroke(Path(roundedRect: square.insetBy(dx: 0.35, dy: 0.35), cornerRadius: corner),
                                       with: .color(.white.opacity(0.7)), lineWidth: 0.7)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Over the empty grid, why it's empty.
    private var note: some View {
        Text(noteText)
            .notchFont(size: 10, weight: .medium)
            .foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, ContributionLayout.monthRow)
            .allowsHitTesting(false)
    }

    private var noteText: String {
        switch trouble {
        case .noTool: return "Install GitHub's gh tool and sign in with gh auth login for your contributions here"
        case .signedOut: return "Sign in with gh auth login in a terminal for your contributions here"
        case .failed: return "Couldn't reach GitHub just now"
        case nil: return reading ? "Reading your contributions from GitHub…" : "Your contributions come from GitHub"
        }
    }

    private var help: String {
        guard grid != nil else { return "Your GitHub contributions this past year, read with GitHub's gh tool" }
        switch trouble {
        case .signedOut: return "As last read: gh is signed out now. Click a day to see it on GitHub"
        case .failed, .noTool: return "As last read: GitHub couldn't be reached just now. Click a day to see it on GitHub"
        case nil: return "Your GitHub contributions this past year. Click a day to see what you did on GitHub"
        }
    }

    /// The day pointed at on GitHub (your profile's activity that day), or your profile.
    private func open() {
        guard let grid, var link = URLComponents(string: "https://github.com/") else { return }
        link.path = "/" + grid.login
        if let day = pointed.value {
            link.queryItems = [URLQueryItem(name: "tab", value: "overview"), URLQueryItem(name: "from", value: day.date),
                               URLQueryItem(name: "to", value: day.date)]
        }
        if let url = link.url { NSWorkspace.shared.open(url) }
    }

    /// Before there's been a read: a year of empty days.
    private static let blank: [[GitHubContributions.Day]] =
        (0..<53).map { week in (0..<7).map { GitHubContributions.Day(date: "\(week)-\($0)", weekday: $0, count: 0, level: 0) } }
}

/// Midnight Oyl's grid, a star chart (see `ContributionsRow`).
private struct StarChart: View {
    let weeks: [[GitHubContributions.Day]]
    let layout: ContributionLayout
    let today: String?
    let pointed: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, _ in
                // A run of bright days in a week, joined.
                var lines = Path()
                for (index, week) in weeks.enumerated() {
                    for (day, next) in zip(week, week.dropFirst()) where day.level >= 3 && next.level >= 3 {
                        lines.move(to: layout.center(week: index, weekday: day.weekday))
                        lines.addLine(to: layout.center(week: index, weekday: next.weekday))
                    }
                }
                context.stroke(lines, with: .color(Midnight.starlight.opacity(0.22)), lineWidth: 0.5)
                let unit = layout.cell / 5
                for (index, week) in weeks.enumerated() {
                    for day in week {
                        let center = layout.center(week: index, weekday: day.weekday)
                        let seed = Double(UInt(bitPattern: (index * 7 + day.weekday) &* 2_654_435_761) % 10_007) / 10_007
                        let twinkle = day.level >= 3 ? 0.5 + 0.5 * sin(time * (0.9 + 1.6 * seed) + seed * 2 * .pi) : 0.5
                        let isPointed = day.date == pointed
                        if isPointed {
                            let reach = layout.pitch * 1.6
                            context.fill(Path(ellipseIn: CGRect(x: center.x - reach, y: center.y - reach, width: 2 * reach, height: 2 * reach)),
                                         with: .radialGradient(Gradient(colors: [Midnight.moonlight.opacity(0.35), Midnight.moonlight.opacity(0)]),
                                                               center: center, startRadius: 0, endRadius: reach))
                        }
                        let swell: CGFloat = isPointed ? 1.5 : 1
                        var star = context
                        switch day.level {
                        case 0:
                            star.opacity = isPointed ? 0.5 : 0.14
                            star.fill(dot(center, 0.45 * unit * swell), with: .color(Midnight.starlight))
                        case 1, 2:
                            star.opacity = day.level == 1 ? 0.45 : 0.65
                            star.fill(dot(center, (day.level == 1 ? 0.8 : 1.1) * unit * swell), with: .color(Midnight.starlight))
                        default:
                            star.opacity = (day.level == 3 ? 0.7 : 0.85) + 0.15 * twinkle
                            if day.level == 4 {
                                let reach = (2.2 + 0.5 * twinkle) * unit * swell
                                star.fill(FourPointStar().path(in: CGRect(x: center.x - reach, y: center.y - reach, width: 2 * reach, height: 2 * reach)),
                                          with: .color(Midnight.starlight))
                            }
                            star.fill(dot(center, (day.level == 3 ? 1.35 : 1.1) * unit * swell * (0.9 + 0.2 * twinkle)),
                                      with: .color(Midnight.white))
                        }
                        if day.date == today {
                            let ring = 2.3 * unit
                            context.stroke(Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: 2 * ring, height: 2 * ring)),
                                           with: .color(Midnight.moonlight.opacity(0.6)), lineWidth: 0.5)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func dot(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }
}
