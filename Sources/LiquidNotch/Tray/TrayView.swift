import AppKit
import EventKit
import IslandCore
import SwiftUI
import UniformTypeIdentifiers

/// The tray's tools on the open card (sim `#tray`): the whole card on the empty notch, or a column beside the
/// player (a hairline between them, 12 pt past the player's 20 pt margin). The column is 128 pt tall between
/// 20 pt margins; it lays out at the card's final size and rides the spring like every card.
struct TrayLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let card: CardSize
    let withPlayer: Bool
    let playerWidth: Double

    var body: some View {
        CardPlacement(frame: frame, card: card) {
            let left = withPlayer ? playerWidth + 4 : 20
            ZStack(alignment: .topLeading) {
                if withPlayer {
                    Rectangle().fill(.white.opacity(0.1))
                        .frame(width: 1, height: card.height - 56)
                        .offset(x: playerWidth - 8, y: 28)
                }
                TrayPages(tray: director.tray, director: director)
                    .frame(width: max(card.width - left - 20, 0), height: card.height - 40, alignment: .topLeading)
                    .offset(x: left, y: 20)
            }
            .frame(width: card.width, height: card.height, alignment: .topLeading)
            .foregroundStyle(.white)
        }
    }
}

/// The grid, or one tool's page sliding in over it.
private struct TrayPages: View {
    let tray: TrayModel
    let director: IslandDirector
    @Environment(\.islandMotion) private var motion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch tray.page {
                case .main: TrayGrid(tray: tray, director: director)
                case .timer: TimerPage(tray: tray, director: director)
                case .focus: FocusPage(tray: tray)
                case .clipboard: ClipboardPage(tray: tray)
                case .shelf: ShelfPage(tray: tray)
                case .shortcuts: ShortcutsPage(tray: tray)
                case .today: TodayPage(tray: tray, director: director)
                }
            }
            .id(tray.page)
            .transition(motion.reduce ? .opacity : .opacity.combined(with: .offset(x: 10)))
        }
        .animation(motion.stills ? nil : .spring(response: motion.seconds(0.3), dampingFraction: 0.85), value: tray.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Grid

/// Six tools in a 3×2 grid: 40 pt circles with 11 pt labels, the rows 10 pt apart.
private struct TrayGrid: View {
    let tray: TrayModel
    let director: IslandDirector

    var body: some View {
        let timer = director.trayTimerLeft
        let running = director.trayRunning
        let rec = director.recordState
        // 4 × 2 (11-06, sim v58): Ask, Timer, Record, Focus / Pause, Clipboard, Shelf, Shortcuts.
        VStack(spacing: 0) {
        Grid(horizontalSpacing: 0, verticalSpacing: 10) {
            GridRow {
                // Quick ask (phase 3): Claude or ChatGPT, with the screen (⌃⌥⌘A anywhere).
                Tool(symbol: "sparkles", label: "Ask") { director.openAsk() }
                    .help("Ask Claude or ChatGPT about your screen (⌥Space)")
                Tool(symbol: "timer", label: timer.map(clockText) ?? "Timer", tint: timer != nil ? IslandColor.orange : nil) { tray.go(.timer) }
                Tool(symbol: "record.circle", label: rec.map { $0.counting ? "Starting" : clockText($0.seconds) } ?? "Record",
                     tint: rec != nil ? IslandColor.red : nil) { director.recordToggle() }
                Tool(symbol: "moon", label: tray.focusName ?? tray.focus?.rawValue ?? "Focus", tint: tray.focusName != nil || tray.focus != nil ? IslandColor.indigo : nil) { tray.go(.focus) }
                // Today's calendar: labelled with what's next ("12:30"), so the grid already answers "what's next".
                Tool(symbol: "calendar", label: TodayPage.nextLabel(director.agenda, now: Date()) ?? "Today") { tray.go(.today) }
            }
            GridRow {
                Tool(symbol: running ? "pause" : "play", label: running ? "Pause" : "Play") { director.trayPause() }
                    .disabled(!director.trayCanPause)
                Tool(symbol: "clipboard", label: "Clipboard") { tray.go(.clipboard) }
                Tool(symbol: "tray", label: "Shelf", badge: tray.files.isEmpty ? nil : tray.files.count) { tray.go(.shelf) }
                Tool(symbol: "square.on.square", label: "Shortcuts") { tray.go(.shortcuts) }
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Tool: View {
    let symbol: String
    let label: String
    var tint: Color?
    var badge: Int?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(tint ?? .white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(tint.map { $0.opacity(0.3) } ?? .white.opacity(0.14)))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text("\(badge)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(.white))
                                .offset(x: 8, y: -4)
                        }
                    }
                    .opacity(enabled ? 1 : 0.4)
                Text(label).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(enabled ? 0.65 : 0.33))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Pages

/// A tool's page: back, the title, an optional action; the body below fills the rest.
private struct Page<Content: View>: View {
    let tray: TrayModel
    let title: String
    var action: (label: String, run: () -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { tray.go(.main) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Back")
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                if let action {
                    Button(action.label, action: action.run).buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(height: 28)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Two by two, 8 pt apart, filling the page's body.
private struct Pills<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) { content }
    }
}

private struct Pill<Icon: View>: View {
    let label: String
    var on = false
    var centred = false
    @ViewBuilder let icon: Icon
    let action: () -> Void
    @State var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                Text(label).lineLimit(1).minimumScaleFactor(0.85)   // "Do Not Disturb" in the column beside the player
                if !centred { Spacer(minLength: 0) }
            }
            .font(.system(size: centred ? 15 : 13, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? IslandColor.indigo.opacity(0.32) : .white.opacity(over ? 0.16 : 0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(pressed: 0.95, hover: 1))
        .onHover { over = $0 }
    }
}

/// Today's calendar (every calendar: classes, meals, work): all-day events as chips on top, then the day as a list
/// with what's on now lit and its time left, scrolled to now. A row opens Calendar at that day.
private struct TodayPage: View {
    let tray: TrayModel
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    /// The tool's label: the next start time, or "Now" while something's on and nothing is next today.
    static func nextLabel(_ agenda: [AgendaItem], now: Date) -> String? {
        let timed = agenda.filter { !$0.allDay }
        if let next = timed.first(where: { $0.start > now }) { return next.start.formatted(date: .omitted, time: .shortened) }
        return timed.contains { $0.isNow(now) } ? "Now" : nil
    }

    var body: some View {
        let _ = director.now
        let now = Date()
        let allDay = director.agenda.filter(\.allDay)
        let timed = director.agenda.filter { !$0.allDay }
        Page(tray: tray, title: now.formatted(.dateTime.weekday(.wide).day().month()),
             action: (label: "Calendar", run: { NSWorkspace.shared.open(URL(string: "ical://")!) })) {
            if director.island.dayLarge && !director.agenda.isEmpty {
                DayLarge(director: director, now: now)
            } else if director.agenda.isEmpty {
                Text(EKAccess.granted ? "Nothing on today" : "Allow Calendar in Setup to see your day")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            if !allDay.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(allDay) { e in
                                            Text(presenting ? "Event" : e.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                                .padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(Capsule().fill(Color(hex: e.colorHex).opacity(0.35)))
                                        }
                                    }
                                }
                                .padding(.bottom, 2)
                            }
                            ForEach(timed) { e in
                                AgendaRow(item: e, now: now).id(e.id)
                            }
                        }
                    }
                    .onAppear {
                        let target = timed.first { $0.isNow(now) } ?? timed.first { $0.start > now }
                        if let target { proxy.scrollTo(target.id, anchor: .top) }
                    }
                }
            }
        }
    }
}

/// Your day at the lyrics player's size: what's on now as a hero on the left (the ring, the time left large, a line
/// bar for how far it has gone, what's next), and the day as a timeline on the right, scrolled to now.
private struct DayLarge: View {
    let director: IslandDirector
    let now: Date
    @Environment(\.presenting) private var presenting

    var body: some View {
        let timed = director.agenda.filter { !$0.allDay }
        let current = timed.last { $0.isNow(now) }
        let next = timed.first { $0.start > now }
        HStack(alignment: .top, spacing: 18) {
            hero(current, next: next)
                .frame(width: 236)
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1).padding(.vertical, 2)
            timeline(timed)
        }
        .padding(.top, 6)
    }

    @ViewBuilder private func hero(_ e: AgendaItem?, next: AgendaItem?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e {
                let total = max(e.end.timeIntervalSince(e.start), 60)
                let gone = min(max(now.timeIntervalSince(e.start) / total, 0), 1)
                let left = Int((e.end.timeIntervalSince(now) / 60).rounded(.up))
                let tint = left <= 5 ? IslandColor.red : Color(hex: e.colorHex)
                Text("NOW").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(tint)
                Text(presenting ? "Event" : e.title).font(.system(size: 17, weight: .semibold)).lineLimit(2).padding(.top, 4)
                Text("\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.55)).padding(.top, 2)
                Spacer(minLength: 10)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(left >= 60 ? "\(left / 60)h \(left % 60)m" : "\(left)m")
                        .font(.system(size: 34, weight: .semibold).monospacedDigit())
                        .foregroundStyle(left <= 5 ? IslandColor.red : .white)
                        .contentTransition(.numericText())
                    Text("left").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                LineBar(progress: gone, tint: tint).frame(height: 6).padding(.top, 8)
                HStack {
                    Text(e.calendar).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(Int((gone * 100).rounded()))%").monospacedDigit()
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.top, 6)
            } else {
                Text("FREE").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(IslandColor.green)
                Text("Nothing on right now").font(.system(size: 17, weight: .semibold)).padding(.top, 4)
                Spacer(minLength: 10)
            }
            if let next {
                let mins = Int((next.start.timeIntervalSince(now) / 60).rounded(.up))
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: next.colorHex)).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Next · " + (mins >= 60 ? "in \(mins / 60)h \(mins % 60)m" : "in \(mins) min"))
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                        Text(presenting ? "Event" : next.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func timeline(_ timed: [AgendaItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(timed) { e in
                        let on = e.isNow(now), past = e.end <= now
                        HStack(alignment: .center, spacing: 10) {
                            Text(e.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11, weight: on ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(.white.opacity(on ? 0.9 : 0.45))
                                .frame(width: 58, alignment: .trailing)
                            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: e.colorHex)).frame(width: 3, height: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(presenting ? "Event" : e.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                                Text(e.calendar.isEmpty ? e.end.formatted(date: .omitted, time: .shortened)
                                     : "until \(e.end.formatted(date: .omitted, time: .shortened)) · \(e.calendar)")
                                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(on ? 0.1 : 0)))
                        .opacity(past ? 0.4 : 1)
                        .id(e.id)
                    }
                }
            }
            .onAppear {
                let target = timed.first { $0.isNow(now) } ?? timed.first { $0.start > now }
                if let target { proxy.scrollTo(target.id, anchor: .top) }
            }
        }
    }
}

/// A line progress bar, as the brightness HUD's: a dim track with the filled part in the tint.
struct LineBar: View {
    let progress: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.white.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: max(geo.size.height, geo.size.width * min(max(progress, 0), 1)))
                }
        }
    }
}

private struct AgendaRow: View {
    let item: AgendaItem
    let now: Date
    @Environment(\.presenting) private var presenting

    var body: some View {
        let on = item.isNow(now)
        let past = item.end <= now
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: item.colorHex)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(presenting ? "Event" : item.title).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                Text(detail(on: on)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if on {
                Text("NOW").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color(hex: item.colorHex).opacity(0.5)))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(on ? 0.12 : 0)))
        .opacity(past ? 0.4 : 1)
    }

    private func detail(on: Bool) -> String {
        let t = "\(item.start.formatted(date: .omitted, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))"
        if on {
            let left = Int(item.end.timeIntervalSince(now) / 60)
            return t + " · " + (left >= 60 ? "\(left / 60)h \(left % 60)m left" : "\(left)m left")
        }
        return item.calendar.isEmpty ? t : t + " · " + item.calendar
    }
}

/// Whether Calendar is allowed (for the Today page's empty state).
enum EKAccess {
    static var granted: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
}

private struct TimerPage: View {
    let tray: TrayModel
    let director: IslandDirector

    var body: some View {
        Page(tray: tray, title: "Timer") {
            Pills {
                ForEach([1, 5, 10, 25], id: \.self) { m in
                    Pill(label: "\(m) min", centred: true) { EmptyView() } action: { director.startTimer(minutes: m) }
                }
            }
        }
    }
}

private struct FocusPage: View {
    let tray: TrayModel

    var body: some View {
        Page(tray: tray, title: "Focus") {
            Pills {
                ForEach(TrayModel.FocusMode.allCases) { mode in
                    Pill(label: mode.rawValue, on: tray.focus == mode) {
                        Image(systemName: mode.symbol).font(.system(size: 13))
                            .foregroundStyle(tray.focus == mode ? Color(hex: "#A9A7FF") : .white)
                            .frame(width: 16)
                    } action: { tray.pick(mode) }
                }
            }
        }
    }
}

private struct ShortcutsPage: View {
    let tray: TrayModel
    private static let colors = [IslandColor.orange, IslandColor.cyan, IslandColor.green, IslandColor.red]

    var body: some View {
        let names = tray.pinnedShortcuts
        Page(tray: tray, title: "Shortcuts") {
            if tray.shortcuts == nil {
                Empty(text: "Loading…")
            } else if names.isEmpty {
                Empty(text: "No shortcuts yet")
            } else {
                Pills {
                    ForEach(Array(names.enumerated()), id: \.element) { i, name in
                        let done = tray.done == "sc\(name)"
                        Pill(label: name) {
                            Image(systemName: done ? "checkmark" : "square.on.square")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(done ? IslandColor.green : Self.colors[i % Self.colors.count]))
                        } action: { tray.run(name) }
                    }
                }
            }
        }
    }
}

private struct ClipboardPage: View {
    let tray: TrayModel
    @Environment(\.presenting) private var presenting

    var body: some View {
        Page(tray: tray, title: "Clipboard", action: tray.clips.isEmpty ? nil : ("Clear", { tray.clearClips() })) {
            if tray.clips.isEmpty {
                Empty(text: "Nothing copied yet")
            } else {
                VStack(spacing: 6) {
                    ForEach(tray.clips.prefix(3)) { clip in
                        Button { tray.copy(clip) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: clip.isLink ? "link" : "text.alignleft")
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(width: 15)
                                // Presenting: what was copied stays private.
                                Text(presenting ? "Copied text" : clip.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                if tray.done == "clip\(clip.id)" {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(IslandColor.green)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle(pressed: 0.97, hover: 1))
                    }
                }
            }
        }
    }
}

private struct ShelfPage: View {
    let tray: TrayModel

    var body: some View {
        Page(tray: tray, title: "Shelf", action: tray.files.isEmpty ? nil : ("Clear", { tray.clearFiles() })) {
            if tray.files.isEmpty {
                Empty(text: "Drop files on the notch", dashed: true)
            } else {
                let shown = Array(tray.files.prefix(4)), more = tray.files.count - shown.count
                HStack(spacing: 6) {
                    ForEach(shown, id: \.self) { ShelfTile(url: $0) }
                    if more > 0 {
                        Text("+\(more)").font(.system(size: 13, weight: .semibold))
                            .frame(width: 40, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1)))
                            .frame(width: 60)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A file on the shelf: its Finder icon and name. Drag it out to put it somewhere; click to open it.
private struct ShelfTile: View {
    let url: URL
    @State var over = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 56)
        }
        .frame(width: 60).frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(over ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { over = $0 }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .accessibilityLabel(url.lastPathComponent)
    }
}

private struct Empty: View {
    let text: String
    var dashed = false

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
    }
}
