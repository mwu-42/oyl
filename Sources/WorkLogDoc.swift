import Foundation

/// The work log as a document: an overview of every project, then a tab for each #tag (its
/// story so far, then month by month, each month's story over its days, in your own words), and
/// a tab of every day. As a page (`Work Log.html`, in Oyl's look: its own, black and rounded; or
/// Midnight Oyl's, engraved, in Victorian type, under a turning sky) and as Markdown
/// (`Work Log.md`, to paste anywhere). Printed, the page is every tab, one after another, in
/// black on white. What you wrote goes in as text, never as markup.
struct WorkLogDoc {
    static let htmlName = "Work Log.html"
    static let markdownName = "Work Log.md"

    struct Day {
        let date: Date
        let texts: [String]
    }

    struct Month {
        let title: String
        let chapter: String?
        let days: [Day]
    }

    struct Tab {
        let tag: String
        let name: String
        let story: String?
        let months: [Month]
        let first: Date
        let last: Date
        let dayCount: Int
    }

    struct Dated {
        let date: Date
        let parts: [(tag: String, text: String)]
    }

    let tabs: [Tab]
    let days: [Dated]
    let now: Date
    /// Whether the stories can be written on this Mac.
    let writes: Bool
    let calendar: Calendar

    @MainActor
    init(log: WorkLog, now: Date) {
        self.now = now
        calendar = log.calendar
        writes = WorkLog.onDevice?.isAvailable ?? false
        let entries = log.saved.entries
        tabs = log.projects.compactMap { project in
            let mine = entries.filter { $0.tag == project.tag }
            guard let first = mine.map(\.day).min(), let last = mine.map(\.day).max() else { return nil }
            let months = log.months(of: project.tag).map { month in
                let byDay = Dictionary(grouping: mine.filter { log.month(of: $0.day) == month }, by: \.day).sorted { $0.key < $1.key }
                return Month(title: log.monthTitle(month), chapter: log.saved.chapters[WorkLog.chapterKey(project.tag, month)]?.text,
                             days: byDay.map { Day(date: $0.key, texts: $0.value.map(\.text)) })
            }
            return Tab(tag: project.tag, name: project.name, story: log.saved.stories[project.tag]?.text, months: months,
                       first: first, last: last, dayCount: Set(mine.map(\.day)).count)
        }
        let names = Dictionary(log.saved.projects.map { ($0.tag, $0.name) }, uniquingKeysWith: { a, _ in a })
        days = Dictionary(grouping: entries, by: \.day).sorted { $0.key > $1.key }.map { day, entries in
            Dated(date: day, parts: entries.map { (names[$0.tag] ?? $0.tag, $0.text) })
        }
    }

    // MARK: Dates

    static func dayTitle(_ day: Date, calendar: Calendar = .current, year: Bool = false) -> String {
        format(year ? "EEE, MMM d, yyyy" : "EEE, MMM d", calendar).string(from: day)
    }

    private static func format(_ pattern: String, _ calendar: Calendar) -> DateFormatter {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = pattern
        return format
    }

    /// "Nov 3 – Nov 5, 2026", or one day.
    func span(_ tab: Tab) -> String {
        let year = calendar.component(.year, from: tab.first) == calendar.component(.year, from: tab.last)
        let start = Self.format(year ? "MMM d" : "MMM d, yyyy", calendar).string(from: tab.first)
        let end = Self.format("MMM d, yyyy", calendar).string(from: tab.last)
        return tab.first == tab.last ? end : "\(start) – \(end)"
    }

    func meta(_ tab: Tab) -> String {
        "\(tab.dayCount) \(tab.dayCount == 1 ? "day" : "days") · \(span(tab))"
    }

    private var updated: String {
        Self.format("MMMM d, yyyy 'at' h:mm a", calendar).string(from: now)
    }

    /// In place of a story not written (yet).
    private var unwritten: String {
        writes ? "Being written…" : "Stories are written on this Mac by Apple Intelligence, which isn't on. Your words are all here."
    }

    // MARK: Markdown

    func markdown() -> String {
        var out = "# Work Log\n\nFrom your check-ins with Oyl. Updated \(updated).\n"
        if tabs.isEmpty { out += "\nNo check-ins yet.\n" }
        for tab in tabs {
            out += "\n## \(tab.name) (#\(tab.tag))\n\n\(meta(tab))\n\n### The story so far\n\n\(tab.story ?? unwritten)\n"
            for month in tab.months {
                out += "\n### \(month.title)\n\n"
                if let chapter = month.chapter { out += "_\(chapter)_\n\n" }
                for day in month.days {
                    let words = day.texts.joined(separator: "\n").replacingOccurrences(of: "\n", with: "\n  ")
                    out += "- **\(Self.dayTitle(day.date, calendar: calendar))**: \(words)\n"
                }
            }
        }
        return out
    }

    // MARK: The page

    func html(look: NotchTheme) -> String {
        var nav = ##"<a href="#_overview" data-tab="_overview">Overview</a>"##
        for tab in tabs { nav += ##"<a href="#\##(Self.attribute(tab.tag))" data-tab="\##(Self.attribute(tab.tag))">#\##(Self.text(tab.name))</a>"## }
        nav += ##"<a href="#_days" data-tab="_days">Every day</a>"##

        var overview = ""
        if tabs.isEmpty { overview = ##"<p class="empty">No check-ins yet. Tell the notch what you got done today, a #tag for each project.</p>"## }
        for (index, tab) in tabs.enumerated() {
            overview += ##"<article class="project" style="--order:\##(index)"><h2><a href="#\##(Self.attribute(tab.tag))">\##(Self.text(tab.name))</a>"##
                + ##" <span class="tag">#\##(Self.text(tab.tag))</span></h2><p class="meta">\##(Self.text(meta(tab)))</p>"##
                + ##"<p class="story\##(tab.story == nil ? " unwritten" : "")">\##(Self.text(tab.story ?? unwritten))</p></article>"##
        }

        var sections = ##"<section class="tab" id="tab-_overview"><h2 class="title">Overview</h2>\##(overview)</section>"##
        for tab in tabs {
            var body = ##"<div class="head"><h2 class="title">\##(Self.text(tab.name))</h2><span class="tag">#\##(Self.text(tab.tag))</span>"##
                + ##"<button class="copy" type="button">Copy</button></div><p class="meta">\##(Self.text(meta(tab)))</p>"##
                + ##"<h3>The story so far</h3><p class="story\##(tab.story == nil ? " unwritten" : "")">\##(Self.text(tab.story ?? unwritten))</p>"##
            for (index, month) in tab.months.enumerated() {
                body += ##"<div class="month" style="--order:\##(index + 1)"><h3>\##(Self.text(month.title))</h3>"##
                if let chapter = month.chapter { body += ##"<p class="chapter">\##(Self.text(chapter))</p>"## }
                for day in month.days {
                    body += ##"<div class="day"><div class="date">\##(Self.text(Self.dayTitle(day.date, calendar: calendar)))</div><div class="words">"##
                        + day.texts.map { "<p>" + Self.text($0) + "</p>" }.joined() + "</div></div>"
                }
                body += "</div>"
            }
            sections += ##"<section class="tab" id="tab-\##(Self.attribute(tab.tag))" hidden>\##(body)</section>"##
        }
        var every = ##"<div class="head"><h2 class="title">Every day</h2><button class="copy" type="button">Copy</button></div>"##
        if days.isEmpty { every += ##"<p class="empty">No check-ins yet.</p>"## }
        for (index, day) in days.enumerated() {
            every += ##"<div class="day" style="--order:\##(min(index, 12))"><div class="date">\##(Self.text(Self.dayTitle(day.date, calendar: calendar, year: true)))</div><div class="words">"##
                + day.parts.map { ##"<p><span class="tag">#\##(Self.text($0.tag))</span> \##(Self.text($0.text))</p>"## }.joined() + "</div></div>"
        }
        sections += ##"<section class="tab" id="tab-_days" hidden>\##(every)</section>"##

        return Self.page
            .replacingOccurrences(of: "{{look}}", with: look == .midnight ? "midnight" : "standard")
            .replacingOccurrences(of: "{{updated}}", with: Self.text("Updated " + updated))
            .replacingOccurrences(of: "{{nav}}", with: nav)
            .replacingOccurrences(of: "{{sections}}", with: sections)
    }

    /// As text in the page: nothing in it is markup, and its lines stay lines.
    static func text(_ string: String) -> String {
        attribute(string).replacingOccurrences(of: "\n", with: "<br>")
    }

    static func attribute(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: Writing it

    /// Into the first of `folders` it can be written to; where it went.
    static func write(html: String, markdown: String, into folders: [URL]) -> URL? {
        for folder in folders {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(html.utf8).write(to: folder.appendingPathComponent(htmlName), options: .atomic)
                try Data(markdown.utf8).write(to: folder.appendingPathComponent(markdownName), options: .atomic)
                return folder.appendingPathComponent(htmlName)
            } catch {
                WorkLog.log.error("Couldn't write the log's document: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    static let page = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Work Log</title>
    <style>
    :root { color-scheme: dark; --bg: #000; --fg: #fff; --soft: rgba(255,255,255,.66); --faint: rgba(255,255,255,.38);
      --card: rgba(255,255,255,.07); --fill: rgba(255,255,255,.12); }
    * { box-sizing: border-box; }
    html { background: var(--bg); }
    body { margin: 0; min-height: 100vh; background: var(--bg); color: var(--fg); -webkit-font-smoothing: antialiased;
      font: 15px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
    :root:has(body[data-look=midnight]) { --bg: #04050a; }
    #sky { position: fixed; inset: 0; width: 100%; height: 100%; pointer-events: none; display: none; }
    .page { position: relative; max-width: 780px; margin: 0 auto; padding: 36px 24px 64px; }
    header h1 { font-size: 30px; font-weight: 700; margin: 0; letter-spacing: -.01em; }
    header .quiet { color: var(--faint); margin: 2px 0 20px; font-size: 13px; }
    nav { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 26px; }
    nav a { color: var(--soft); text-decoration: none; padding: 6px 13px; border-radius: 999px; background: var(--card); font-size: 13px; font-weight: 600; }
    nav a.on { background: var(--fg); color: var(--bg); }
    a { color: inherit; }
    h2.title { font-size: 22px; margin: 0; }
    .head { display: flex; align-items: baseline; gap: 10px; }
    .head .copy { margin-left: auto; }
    .tag { color: var(--faint); font-weight: 600; font-size: .86em; }
    .meta { color: var(--faint); font-size: 13px; margin: 2px 0 18px; }
    h3 { font-size: 13px; font-weight: 700; text-transform: uppercase; letter-spacing: .07em; color: var(--soft); margin: 26px 0 8px; }
    .story { font-size: 16px; margin: 0; }
    .unwritten { color: var(--faint); font-style: italic; }
    .chapter { color: var(--soft); background: var(--card); border-radius: 14px; padding: 12px 14px; margin: 0 0 10px; }
    .day { display: flex; gap: 16px; padding: 7px 0; }
    .day .date { flex: none; width: 112px; color: var(--faint); font-size: 13px; font-weight: 600; font-variant-numeric: tabular-nums; padding-top: 1px; }
    .day .words p { margin: 0 0 4px; }
    .project { background: var(--card); border-radius: 18px; padding: 16px 18px; margin: 14px 0; }
    .project h2 { font-size: 18px; margin: 0; }
    .project h2 a { text-decoration: none; }
    .project .meta { margin-bottom: 8px; }
    .empty { color: var(--faint); }
    button.copy { font: inherit; font-size: 12px; font-weight: 600; color: var(--fg); background: var(--fill); border: 0; border-radius: 999px; padding: 5px 12px; cursor: pointer; }
    button.copy.done { color: var(--soft); }
    [hidden] { display: none !important; }

    /* Midnight Oyl: under a turning sky, engraved, in Victorian type, everything drifting in, and off to one side. */
    body[data-look=midnight] { --bg: #04050a; --fg: #f2f5fa; --soft: rgba(196,202,216,.92); --faint: rgba(179,186,204,.58); --card: transparent;
      font-family: Georgia, "Hoefler Text", serif; font-size: 16px; }
    body[data-look=midnight] #sky { display: block; }
    body[data-look=midnight] .page { margin-left: max(24px, 9vw); padding-right: 12vw; }
    body[data-look=midnight] header h1 { font-family: Superclarendon, "Bodoni 72", Didot, serif; font-weight: 300; font-size: 38px; }
    body[data-look=midnight] header .quiet { font-family: Superclarendon, Georgia, serif; font-style: italic; font-size: 14px; }
    body[data-look=midnight] nav { gap: 4px 20px; }
    body[data-look=midnight] nav a { background: none; border-radius: 0; padding: 6px 1px 4px; font-family: Copperplate, serif; font-weight: 400;
      letter-spacing: .14em; text-transform: uppercase; font-size: 12px;
      background-image: linear-gradient(90deg, transparent, rgba(214,222,237,.45), transparent); background-size: 100% 1px;
      background-position: 0 100%; background-repeat: no-repeat; transition: color .4s; }
    body[data-look=midnight] nav a.on { color: var(--fg); background-color: transparent; }
    body[data-look=midnight] nav a.on::before { content: "\2726\00a0"; animation: twinkle 2.4s ease-in-out infinite; display: inline-block; }
    body[data-look=midnight] h2.title, body[data-look=midnight] .project h2 { font-family: Superclarendon, Georgia, serif; font-weight: 400; font-size: 26px; }
    body[data-look=midnight] .project h2 { font-size: 21px; }
    body[data-look=midnight] .tag { font-family: Superclarendon, Georgia, serif; font-style: italic; font-weight: 300; }
    body[data-look=midnight] .meta { font-family: "Bodoni 72", Didot, serif; font-size: 14px; }
    body[data-look=midnight] h3 { font-family: Copperplate, serif; font-weight: 400; letter-spacing: .16em; font-size: 12px; position: relative; padding-top: 14px; }
    body[data-look=midnight] h3::before { content: ""; position: absolute; left: -22px; right: 24%; top: 0; height: 1px;
      background: linear-gradient(90deg, transparent, rgba(214,222,237,.36) 16%, rgba(214,222,237,.08) 72%, transparent); }
    body[data-look=midnight] .story { font-family: Superclarendon, Georgia, serif; font-weight: 300; font-size: 17px; line-height: 1.55; }
    body[data-look=midnight] .chapter { background: none; border-radius: 0; padding: 0 0 6px; font-style: italic; margin-left: 6%; }
    body[data-look=midnight] .day .date { font-family: "Bodoni 72", Didot, serif; font-weight: 400; font-size: 14px; }
    body[data-look=midnight] .month:nth-of-type(even) { margin-left: 5%; }
    body[data-look=midnight] .project { background: none; border-radius: 0; padding: 6px 0 10px; }
    body[data-look=midnight] .project:nth-of-type(even) { margin-left: 7%; }
    body[data-look=midnight] button.copy { background: none; border-radius: 0; padding: 4px 1px 2px; font-family: Copperplate, serif; font-weight: 400;
      letter-spacing: .14em; text-transform: uppercase; color: var(--soft);
      background-image: linear-gradient(90deg, transparent, rgba(214,222,237,.5), transparent); background-size: 100% 1px;
      background-position: 0 100%; background-repeat: no-repeat; }
    body[data-look=midnight] .tab > * { transition: opacity .8s cubic-bezier(.2,.7,.2,1), filter .8s cubic-bezier(.2,.7,.2,1), transform .8s cubic-bezier(.2,.7,.2,1);
      transition-delay: calc(var(--order, 0) * 60ms); }
    body[data-look=midnight] .tab.arriving > * { opacity: 0; filter: blur(3px); transform: translateX(-8px); transition: none; }
    @keyframes twinkle { 50% { opacity: .3; } }

    @media print {
      :root, body[data-look=midnight] { --bg: #fff; --fg: #000; --soft: #333; --faint: #666; --card: transparent; color-scheme: light; }
      #sky, nav, button.copy { display: none !important; }
      .tab[hidden] { display: block !important; }
      .tab { break-before: page; }
      .tab:first-of-type { break-before: auto; }
      .page { margin: 0; padding: 0; max-width: none; }
      .chapter, .project { background: none; padding-left: 0; padding-right: 0; }
    }
    @media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation: none !important; transition: none !important; } }
    </style>
    </head>
    <body data-look="{{look}}">
    <canvas id="sky" aria-hidden="true"></canvas>
    <div class="page">
    <header><h1>Work Log</h1><p class="quiet">{{updated}}</p></header>
    <nav id="tabs">{{nav}}</nav>
    <main>{{sections}}</main>
    </div>
    <script>
    // A tab at a time, by the address's #tag (so a link can open one), the overview with none.
    // (The overview's and every day's start with _, which no tag can.)
    function show() {
      const wanted = decodeURIComponent(location.hash.slice(1)) || "_overview";
      const tab = document.getElementById("tab-" + wanted) ? wanted : "_overview";
      for (const section of document.querySelectorAll(".tab")) {
        const on = section.id === "tab-" + tab;
        if (on && section.hidden && document.body.dataset.look === "midnight") {
          section.classList.add("arriving");
          requestAnimationFrame(() => requestAnimationFrame(() => section.classList.remove("arriving")));
        }
        section.hidden = !on;
      }
      for (const link of document.querySelectorAll("nav a")) link.classList.toggle("on", link.dataset.tab === tab);
    }
    addEventListener("hashchange", () => { show(); scrollTo(0, 0); });
    show();

    // A tab's words, to paste into a résumé or a review.
    for (const button of document.querySelectorAll("button.copy")) {
      button.addEventListener("click", async () => {
        const section = button.closest(".tab");
        const text = [...section.querySelectorAll("h2, .tag, .meta, h3, p, .date")]
          .filter((part) => !part.closest(".head") || part.matches("h2"))
          .map((part) => part.matches(".date") ? "\n" + part.innerText : part.matches("h3") ? "\n" + part.innerText.toUpperCase() : part.innerText)
          .join("\n");
        try { await navigator.clipboard.writeText(text.trim()); } catch {
          const area = document.createElement("textarea");
          area.value = text.trim(); document.body.append(area); area.select(); document.execCommand("copy"); area.remove();
        }
        button.textContent = "Copied"; button.classList.add("done");
        setTimeout(() => { button.textContent = "Copy"; button.classList.remove("done"); }, 1600);
      });
    }

    // Midnight's sky: stars turning slowly round a pole up to the left, twinkling, with now and
    // then a shooting star.
    (() => {
      if (document.body.dataset.look !== "midnight") return;
      const canvas = document.getElementById("sky"), pen = canvas.getContext("2d");
      const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
      let width = 0, height = 0, stars = [], streak = null;
      function size() {
        const scale = devicePixelRatio || 1;
        width = innerWidth; height = innerHeight;
        canvas.width = width * scale; canvas.height = height * scale;
        pen.setTransform(scale, 0, 0, scale, 0, 0);
        const reach = Math.hypot(width, height) * 1.1;
        stars = Array.from({ length: Math.round(width * height / 5200) }, () => ({
          r: Math.sqrt(Math.random()) * reach, a: Math.random() * Math.PI * 2, size: Math.random() ** 3 * 1.5 + .3,
          speed: .6 + Math.random() * .8, phase: Math.random() * 6.28 }));
      }
      function draw(time) {
        const t = time / 1000, pole = { x: width * .12, y: height * .08 };
        pen.clearRect(0, 0, width, height);
        for (const star of stars) {
          const angle = star.a + t * 0.004;
          const x = pole.x + Math.cos(angle) * star.r, y = pole.y + Math.sin(angle) * star.r;
          if (x < -4 || y < -4 || x > width + 4 || y > height + 4) continue;
          const glow = .35 + .65 * (.5 + .5 * Math.sin(t * star.speed + star.phase));
          pen.fillStyle = `rgba(226,232,244,${(.18 + .5 * glow) * Math.min(1, star.size)})`;
          pen.beginPath(); pen.arc(x, y, star.size, 0, Math.PI * 2); pen.fill();
        }
        // Rings of the chart round the pole, engraved faintly.
        pen.strokeStyle = "rgba(214,222,237,.07)"; pen.lineWidth = 1;
        for (const ring of [.22, .41, .63]) { pen.beginPath(); pen.arc(pole.x, pole.y, Math.hypot(width, height) * ring, 0, Math.PI * 2); pen.stroke(); }
        if (!streak && Math.random() < .002) streak = { x: Math.random() * width, y: Math.random() * height * .5, born: t };
        if (streak) {
          const age = (t - streak.born) / .9;
          if (age > 1) streak = null; else {
            const x = streak.x + age * 180, y = streak.y + age * 70;
            const tail = pen.createLinearGradient(x - 60, y - 23, x, y);
            tail.addColorStop(0, "rgba(255,243,220,0)"); tail.addColorStop(1, `rgba(255,243,220,${.7 * (1 - age)})`);
            pen.strokeStyle = tail; pen.lineWidth = 1.2; pen.beginPath(); pen.moveTo(x - 60, y - 23); pen.lineTo(x, y); pen.stroke();
          }
        }
        if (!still) requestAnimationFrame(draw);
      }
      addEventListener("resize", size);
      size(); requestAnimationFrame(draw);
    })();
    </script>
    </body>
    </html>
    """#
}
