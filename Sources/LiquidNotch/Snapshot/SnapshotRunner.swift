import AppKit
import IslandCore
import NowPlaying
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// `LiquidNotch --snapshot <dir>`: renders every island state and scripted transitions offscreen
/// through the real reducer, animator, shader and SwiftUI content, and writes PNG contact sheets.
/// Lets motion be inspected frame by frame without putting anything on screen.
@MainActor
enum SnapshotRunner {
    struct Region { var width: Double; var height: Double }

    static let scale = 2.0

    static func run(outputDirectory: String) {
        // Stills never touch the network (crests are badges unless cached), except README stills (`LN_SNAP_README=1`):
        // those fetch the sample teams' real crests first, as the app does at runtime.
        let readme = ProcessInfo.processInfo.environment["LN_SNAP_README"] != nil
        CrestStore.shared.offline = !readme
        if readme {
            let teams = [FootballSamples.palmeiras, FootballSamples.flamengo, FootballSamples.barcelona, FootballSamples.atletico]
            for t in teams { _ = CrestStore.shared.image(t) }
            let until = Date().addingTimeInterval(6)
            while Date() < until, teams.contains(where: { CrestStore.shared.images[$0.key] == nil }) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let geometry = NotchGeometry.current()?.1
        // LN_SNAP_NOTCH=185x24 draws another Mac's notch, e.g. an M1 Air's virtual one under its 24 pt menu bar.
        let forced = ProcessInfo.processInfo.environment["LN_SNAP_NOTCH"]?.split(separator: "x").compactMap { Double($0) }
        let notchHalfWidth = forced?.count == 2 ? forced![0] / 2 : Double((geometry?.notchWidth ?? 208) / 2)
        let notchHeight = forced?.count == 2 ? forced![1] : Double(geometry?.notchHeight ?? 37.5)
        let tuning = Tuning()

        let renderer: LiquidRenderer
        do { renderer = try LiquidRenderer() } catch { print("snapshot: \(error)"); return }
        let stage = Stage(renderer: renderer, notchHalfWidth: notchHalfWidth, notchHeight: notchHeight, tuning: tuning)

        // Resting shapes, true colours, no content.
        let base = ShapeTargets(notchHalfWidth: notchHalfWidth, notchHeight: notchHeight, tuning: tuning)
        var rest: [CGImage] = []
        for mode in PresentationMode.allCases {
            var t = base
            if mode == .split || mode == .duo { t.context.bubbleModes = [mode] }
            if let img = stage.image(t.restingFrame(mode), targets: t, mode: mode, region: Region(width: 520, height: 220),
                                     content: nil) { rest.append(img) }
        }
        write(grid(rest, columns: 1), to: dir.appendingPathComponent("rest-states.png"))

        // Every island state, with its content, as the reducer arranges it. `LN_SNAP_ONLY=<text>`
        // renders only the states whose name contains it.
        var labelled: [(String, CGImage)] = []
        let only = ProcessInfo.processInfo.environment["LN_SNAP_ONLY"]
        for scenario in Scenario.all where only.map({ scenario.name.contains($0) }) ?? true {
            let d = stage.director()
            scenario.setup(d)
            let (t, mode) = stage.targets(for: d)
            // The tray with a song is 672 pt wide: its states get a wider crop.
            let big = d.groups.playerFocus || d.island.dayLarge
            let width = (d.groups.tray && d.groups.player) || big ? 720.0 : 560
            let height = big ? 400.0 : d.groups.agentsCard != nil ? 380 : 220
            if let img = stage.image(t.restingFrame(mode), targets: t, mode: mode, region: Region(width: width, height: height),
                                     content: d) {
                labelled.append((scenario.name, img))
            }
        }
        write(grid(labelled.map(\.1), columns: 2), to: dir.appendingPathComponent("island-states.png"))
        // `LN_SNAP_EACH=1`: every state on its own too (each/<name>.png), for picking README shots.
        if ProcessInfo.processInfo.environment["LN_SNAP_EACH"] != nil {
            let each = dir.appendingPathComponent("each", isDirectory: true)
            try? FileManager.default.createDirectory(at: each, withIntermediateDirectories: true)
            for (name, img) in labelled {
                let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                write(img, to: each.appendingPathComponent(slug + ".png"))
            }
        }
        let index = labelled.enumerated().map { i, l in "\(i / 2 + 1)\t\(i % 2 == 0 ? "left" : "right")\t\(l.0)" }
        try? (["row\tcolumn\tstate"] + index).joined(separator: "\n")
            .write(to: dir.appendingPathComponent("island-states.tsv"), atomically: true, encoding: .utf8)

        // Opening a card with its content: the art and bars travel from the ears, the card's
        // content rides the spring as one scaled piece.
        for (name, setup) in [("open-player", { (d: IslandDirector) in d.startMusic() }),
                              ("open-call", { (d: IslandDirector) in d.startMusic(); d.show(.call, opened: false) })] {
            let d = stage.director()
            setup(d)
            let (t0, from) = stage.targets(for: d)
            d.pointerDown(at: SIMD2(380, 18), hit: .ears)
            d.pointerUp(at: SIMD2(380, 18), hit: .ears, corridor: false)
            let (t1, to) = stage.targets(for: d)
            let a = stage.animator(t0, from)
            a.snapChannels(ShapeTargets.cardChannels, from: t1.cardSeed)
            let (first, stages) = t1.transition(from: from, to: to)
            a.setTargets(first, then: stages)
            var frames: [CGImage] = []
            for i in 0...(240 * 6 / 10) {
                if i % 12 == 0, let img = stage.image(a.frame, targets: t1, mode: to, region: Region(width: 520, height: 220),
                                                      content: d) { frames.append(img) }
                a.advance(1.0 / 240)
            }
            write(grid(frames, columns: 4), to: dir.appendingPathComponent("\(name).png"))
        }
        // Closing the player: the art and bars ride the shrinking card back into the ears (owner, 11-06: they jumped).
        do {
            let d = stage.director()
            d.startMusic()
            d.pointerDown(at: SIMD2(380, 18), hit: .ears)
            d.pointerUp(at: SIMD2(380, 18), hit: .ears, corridor: false)
            let (t0, from) = stage.targets(for: d)
            d.clickOutside()
            let (t1, to) = stage.targets(for: d)
            let a = stage.animator(t0, from)
            let (first, stages) = t1.transition(from: from, to: to)
            a.setTargets(first, then: stages)
            var frames: [CGImage] = []
            for i in 0...(240 * 6 / 10) {
                var t = t1
                t.context.card = t0.card        // the closing card keeps its size, as the surface does
                if i % 12 == 0, let img = stage.image(a.frame, targets: t, mode: to, region: Region(width: 520, height: 220),
                                                      content: d) { frames.append(img) }
                a.advance(1.0 / 240)
            }
            write(grid(frames, columns: 4), to: dir.appendingPathComponent("close-player.png"))
        }

        // Shape transitions, sampled every 1/30 s, liquid tinted red so it reads against the
        // black of the hardware notch (drawn as an outline).
        let scripts: [(String, PresentationMode, PresentationMode, Set<PresentationMode>, Region)] = [
            ("idle-to-compact", .idle, .compact, [], Region(width: 420, height: 90)),
            ("drip-compact-to-duo", .compact, .duo, [.duo], Region(width: 440, height: 90)),
            ("absorb-duo-to-compact", .duo, .compact, [.duo], Region(width: 440, height: 90)),
            ("compact-to-peek", .compact, .peek, [], Region(width: 440, height: 110)),
            ("compact-to-card", .compact, .card, [], Region(width: 520, height: 220)),
            ("card-to-compact", .card, .compact, [], Region(width: 520, height: 220)),
            ("duo-to-card", .duo, .card, [.duo, .card], Region(width: 520, height: 220)),
            ("compact-to-hud", .compact, .hud, [], Region(width: 520, height: 90)),
            ("card-to-idle", .card, .idle, [], Region(width: 520, height: 220)),
        ]
        for (name, from, to, bubbles, region) in scripts {
            var t = base
            t.context.bubbleModes = bubbles
            let a = stage.animator(t, from)
            if to == .card { a.snapChannels(ShapeTargets.cardChannels, from: t.cardSeed) }
            let (first, stages) = t.transition(from: from, to: to)
            a.setTargets(first, then: stages)
            var frames: [CGImage] = []
            var log = "t\tmainW\tmainH\tdropX\tdropR\tneck\tcardW\tcardTop\tcardH\tcardNeck\n"
            let dt = 1.0 / 240.0
            for i in 0...(240 * 9 / 10) {        // 0.9 s
                if i % 8 == 0 {
                    let f = a.frame
                    let s = t.drawn(f).state
                    log += String(format: "%.3f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\n", Double(i) * dt,
                                  f.state.mainHalfWidth * 2, s.mainHeight, f.state.dropX, f.state.dropRadius, f.neckRadius,
                                  f.state.cardHalfWidth * 2, f.state.cardTop, f.state.cardHeight, f.cardNeck)
                    if let img = stage.image(f, targets: t, mode: to, region: region, content: nil, xray: true) { frames.append(img) }
                }
                a.advance(dt)
            }
            write(grid(frames, columns: 4), to: dir.appendingPathComponent("\(name).png"))
            try? log.write(to: dir.appendingPathComponent("\(name).tsv"), atomically: true, encoding: .utf8)
        }
        // The lock screen's music card, and with its lyrics, over a dark lock-screen stand-in.
        if only.map({ "lock".contains($0) || $0.contains("lock") }) ?? true {
            for name in ["lock-card", "lock-card-lyrics", "lock-card-bare", "lock-card-bare-lyrics"] {
                let d = stage.director()
                d.startMusic()
                d.lockArt = name.contains("bare")
                if name.hasSuffix("lyrics") {
                    let lines = ["I saw you standing there", "under the evening light", "and every word I had", "just slipped out of sight",
                                 "so stay a little longer", "the night is ours to keep"]
                    d.useLyrics(Lyrics(key: LyricsSource.key(title: d.media.title, artist: d.media.artist),
                                       lines: lines.enumerated().map { LyricLine(time: Double($0.offset) * 4 - 6, text: $0.element) }, plain: []))
                }
                d.lockLyrics = name.hasSuffix("lyrics")
                let view = LockMusicCard(director: d)
                    .environment(\.islandMotion, IslandMotion(stills: true))
                    .padding(30)
                    .background(LinearGradient(colors: [Color(hex: "#3B2E5A"), Color(hex: "#1B3B52")], startPoint: .top, endPoint: .bottom))
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.cgImage { write(img, to: dir.appendingPathComponent("\(name).png")) }
                _ = ImageRenderer(content: Color.clear.frame(width: 1, height: 1)).cgImage
            }
        }
        // The desktop's moving colours (11-07), from a sample cover.
        if only.map({ "desktop".contains($0) || $0.contains("desktop") }) ?? true {
            let art = NSImage(size: NSSize(width: 300, height: 300))
            art.lockFocus()
            NSGradient(colors: [NSColor(red: 0.9, green: 0.45, blue: 0.2, alpha: 1), NSColor(red: 0.15, green: 0.2, blue: 0.45, alpha: 1)])!
                .draw(in: NSRect(x: 0, y: 0, width: 300, height: 300), angle: 60)
            NSColor(red: 0.95, green: 0.8, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 170, y: 170, width: 90, height: 90)).fill()
            art.unlockFocus()
            if let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let still = DesktopColors.still(size: CGSize(width: 1710, height: 1112), art: cg) {
                write(still, to: dir.appendingPathComponent("desktop-colors.png"))
            }
        }
        // The setup window, drawn offscreen through AppKit (its controls are AppKit views).
        let setupHost = NSHostingView(rootView: SetupView {}.environment(\.colorScheme, .light))
        setupHost.frame = NSRect(origin: .zero, size: setupHost.fittingSize)
        setupHost.layoutSubtreeIfNeeded()
        if let rep = setupHost.bitmapImageRepForCachingDisplay(in: setupHost.bounds) {
            setupHost.cacheDisplay(in: setupHost.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("setup.png"))
        }
        print("snapshot: wrote \(dir.path)")
    }

    // MARK: - Scenarios

    struct Scenario {
        let name: String
        let setup: @MainActor (IslandDirector) -> Void

        static var all: [Scenario] {
            var list: [Scenario] = [
                Scenario(name: "media · ears") { $0.startMusic() },
                Scenario(name: "media · hover preview") { d in d.startMusic(); d.pointerMoved(hit: .ears, corridor: false, buttonDown: false) },
                Scenario(name: "media · player card") { d in d.startMusic(); d.pointerDown(at: .zero, hit: .ears) },
                Scenario(name: "media · the focused player with lyrics") { d in
                    d.startMusic(); d.pointerDown(at: .zero, hit: .ears)
                    let lines = ["I saw you standing there", "under the evening light", "and every word I had", "just slipped out of sight",
                                 "so stay a little longer", "the night is ours to keep"]
                    d.useLyrics(Lyrics(key: LyricsSource.key(title: d.media.title, artist: d.media.artist),
                                       lines: lines.enumerated().map { LyricLine(time: Double($0.offset) * 4 - 6, text: $0.element) }, plain: []))
                    d.openFocus()
                },
                Scenario(name: "media · the record out of its sleeve") { d in
                    d.startMusic(); d.pointerDown(at: .zero, hit: .ears); d.toggleVinyl()
                },
                Scenario(name: "media + timer · timer in the bubble") { d in d.startMusic(); d.show(.timer) },
                Scenario(name: "media + call · media in the bubble") { d in d.startMusic(); d.show(.call, opened: false) },
                Scenario(name: "media + call · media's card from the bubble") { d in
                    d.startMusic(); d.show(.call, opened: false); d.pointerDown(at: .zero, hit: .bubble(0))
                },
                Scenario(name: "media + timer · AirPods borrow the ears") { d in d.startMusic(); d.show(.timer); d.show(.airpods) },
                // Many things at once (11-06): two balls and the +N ball; its list; a call while recording.
                Scenario(name: "many · call, recording, song, timer, camera") { d in
                    d.startMusic(); d.show(.recording); d.show(.call, opened: false); d.show(.timer); d.show(.camera)
                },
                Scenario(name: "many · the +N list") { d in
                    d.startMusic(); d.show(.recording); d.show(.call, opened: false); d.show(.timer); d.show(.camera)
                    d.show(.download); d.hide(.media)
                    d.pointerDown(at: .zero, hit: .bubble(2))
                },
                Scenario(name: "rest · the empty notch") { _ in },
                Scenario(name: "rest · hovered, a press opens the tray") { d in d.pointerMoved(hit: .ears, corridor: false, buttonDown: false) },
                Scenario(name: "record · 3-2-1") { d in d.recordToggle() },
                Scenario(name: "record · saved") { d in
                    d.show(.recording, opened: false); d.perform(.stopRecording)
                },
                Scenario(name: "record · tray with Record") { d in d.openTray() },
                Scenario(name: "many · paused song and a download get no ball") { d in
                    d.startMusic(); d.togglePlaying(); d.show(.call, opened: false); d.show(.download)
                },
                // Notifications (banners only, 11-11): it arrives as its card, then waits in the ears; the shapes macOS
                // sends (a title alone, a body alone, time-sensitive).
                Scenario(name: "airpane · its one card") { d in d.show(.airPane, opened: true, sample: false) },
                Scenario(name: "support · its one card") { d in d.show(.support, opened: true, sample: false) },
                Scenario(name: "notices · Mail arrives as its card") { d in d.notifySample() },
                Scenario(name: "notices · then in the ears") { d in d.notifySample(); d.clickOutside() },
                Scenario(name: "notices · time sensitive") { d in d.notifySample(); d.clickOutside(); d.notifySample() },
                Scenario(name: "notices · a body alone") { d in
                    for _ in 0..<4 { d.notifySample(); d.clickOutside() }
                    d.notifySample()
                },
                Scenario(name: "notices · arriving over an open player waits in the ears") { d in
                    d.startMusic(); d.pointerDown(at: .zero, hit: .ears); d.notifySample()
                },
                Scenario(name: "real · cover and its colour in the bars") { d in d.nowPlayingChanged(sampleSong()) },
                Scenario(name: "real · player card") { d in
                    d.nowPlayingChanged(sampleSong()); d.pointerDown(at: .zero, hit: .ears)
                },
                // Claude and Codex (phase 2): a ball per provider; needing you, it takes the ears; its card answers.
                Scenario(name: "agents · Claude working beside the song") { d in
                    d.startMusic(); agent(d, "UserPromptSubmit"); agent(d, "PreToolUse", tool: "Edit")
                },
                Scenario(name: "agents · Claude asks to run a command") { d in
                    d.startMusic(); agent(d, "UserPromptSubmit"); agent(d, "PermissionRequest", tool: "Bash")
                },
                Scenario(name: "agents · the approval card") { d in
                    d.startMusic(); agent(d, "UserPromptSubmit"); agent(d, "PermissionRequest", tool: "Bash")
                    sampleChat(d)
                    d.pointerDown(at: .zero, hit: .ears)
                },
                // A ball's own hover (11-06): it swells and its peek hangs under it; the song's ears stay as they are.
                Scenario(name: "agents · a ball's peek") { d in
                    d.startMusic(); agent(d, "UserPromptSubmit"); agent(d, "PreToolUse", tool: "Edit")
                    sampleChat(d)
                    d.pointerMoved(hit: .bubble(0), corridor: false, buttonDown: false)
                },
                // Claude in the ears previews on hover, like a song: the ball slides into the lip beside its session's row.
                Scenario(name: "agents · hovering Claude in the ears") { d in
                    agent(d, "UserPromptSubmit"); agent(d, "PreToolUse", tool: "Edit")
                    sampleChat(d)
                    d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
                },
                // Needing you, a hover shows the question alone (owner, 11-06: "if i hover, only the question").
                Scenario(name: "agents · hovering Claude that asks: the question alone") { d in
                    d.startMusic(); agent(d, "UserPromptSubmit"); agent(d, "PermissionRequest", tool: "Bash")
                    sampleChat(d)
                    d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
                },
                Scenario(name: "agents · hovering its ball while it asks a question") { d in
                    d.show(.recording, opened: false); agent(d, "UserPromptSubmit"); agent(d, "PreToolUse", tool: "AskUserQuestion")
                    let place = d.island.balls(d.mode).firstIndex(of: .agents(.claude)) ?? 0
                    d.pointerMoved(hit: .bubble(place), corridor: false, buttonDown: false)
                },
                // A song's ball peeks like the notch's hover, with the transport (owner, 11-06).
                Scenario(name: "agents · a song's ball peek, with its controls") { d in
                    d.startMusic(); d.show(.recording, opened: false)
                    let place = d.island.balls(d.mode).firstIndex(of: .media) ?? 0
                    d.pointerMoved(hit: .bubble(place), corridor: false, buttonDown: false)
                },
                Scenario(name: "agents · the chat card from its ball") { d in
                    d.startMusic(); agent(d, "UserPromptSubmit", "c2")
                    agent(d, "UserPromptSubmit"); agent(d, "PreToolUse", tool: "Edit")
                    sampleChat(d)
                    d.pointerDown(at: .zero, hit: .bubble(0))
                },
                Scenario(name: "agents · a question, answered in its app") { d in
                    agent(d, "UserPromptSubmit"); agent(d, "PreToolUse", tool: "AskUserQuestion")
                    d.pointerDown(at: .zero, hit: .ears)
                },
                Scenario(name: "agents · Claude done, Codex working, song") { d in
                    d.startMusic(); agent(d, "Stop", "c1"); agent(d, "UserPromptSubmit", "c2"); agent(d, "Stop", "c2")
                    agent(d, "UserPromptSubmit", "x1", .codex); agent(d, "PreToolUse", "x1", .codex, tool: "shell")
                },
                Scenario(name: "agents · a usage limit") { d in
                    agent(d, "UserPromptSubmit"); agent(d, "StopFailure", extra: #","error":"rate_limit""#)
                },
                Scenario(name: "football · the match's ball beside the song") { d in
                    d.startMusic(); d.show(.match, opened: false); advance(d, .match)
                },
                Scenario(name: "football · a goal takes the ears") { d in
                    d.show(.match, opened: false); SnapshotClock.time += 30; d.tick()
                },
                Scenario(name: "football · the goal's card") { d in
                    d.show(.match, opened: false); SnapshotClock.time += 30; d.tick()
                    d.openCard(.activity)
                },
                Scenario(name: "chess · your move beside the song") { d in d.startMusic(); d.show(.chess, opened: false) },
                Scenario(name: "ask · the card on the empty notch") { d in askStub(d); d.openAsk() },
                Scenario(name: "ask · ChatGPT, screen off") { d in askStub(d); d.openAsk(.codex); d.toggleAskShot() },
                Scenario(name: "ask · many conversations: the chips scroll") { d in
                    askStub(d)
                    for q in ["Which opening is this?", "What does the error say?", "Summarise this page", "Translate the title", "Is this safe to run?"] {
                        d.openAsk(new: true); d.submitAsk(q)
                    }
                },
                Scenario(name: "ask · the answer streaming in its chat") { d in
                    askStub(d); d.openAsk(); d.submitAsk("What's the error in this window?")
                    if let id = d.island.agents.sessions.first?.id {
                        d.askEvent(id, .delta("The build fails because `Football.swift` uses `Logger` without importing os. Add "))
                    }
                },
                Scenario(name: "lock · the island while locked, a song playing") { d in
                    d.startMusic(); d.systemContextChanged(DesktopContext(lockScreen: true))
                },
                Scenario(name: "lock · the unlock moment") { d in
                    d.startMusic(); d.systemContextChanged(DesktopContext(lockScreen: true)); d.systemContextChanged(DesktopContext())
                },
                Scenario(name: "volume HUD") { d in d.startMusic(); d.volumeUp() },
                Scenario(name: "brightness HUD") { d in d.startMusic(); d.brightnessUp() },
            ]
            for id in ActivityID.allCases {
                list.append(Scenario(name: "\(id.rawValue) · ears") { d in
                    d.show(id, opened: false); advance(d, id)
                })
                list.append(Scenario(name: "\(id.rawValue) · card") { d in
                    d.show(id, opened: true); advance(d, id)
                    if id == .match { d.openCard(.activity) }   // its goal moments took the ears meanwhile
                })
            }
            list += [
                Scenario(name: "presenting · incoming call, name hidden") { d in
                    d.setContext(DesktopContext(sharing: true)); d.show(.incoming, opened: false)
                },
                Scenario(name: "presenting · incoming card, name hidden") { d in
                    d.setContext(DesktopContext(sharing: true)); d.show(.incoming)
                },
                Scenario(name: "typing · incoming call stays in the ears") { d in
                    d.setContext(DesktopContext(typing: true)); d.show(.incoming)
                },
                Scenario(name: "Music in front · timer takes the ears") { d in
                    d.setContext(DesktopContext(frontmostApp: BundleID.music)); d.startMusic(); d.show(.timer)
                },
                Scenario(name: "fullscreen · hidden") { d in d.setContext(DesktopContext(fullscreen: true)); d.startMusic() },
                Scenario(name: "empty notch · hovered") { d in d.pointerMoved(hit: .ears, corridor: false, buttonDown: false) },
                Scenario(name: "tray · empty notch") { d in d.pointerDown(at: .zero, hit: .ears) },
                Scenario(name: "tray · paused song, second click") { d in
                    d.startMusic(); d.togglePlaying(); d.pointerDown(at: .zero, hit: .ears); d.pointerDown(at: .zero, hit: .ears)
                },
                Scenario(name: "tray · timer running") { d in d.startTimer(minutes: 5); d.startMusic(); d.openTray() },
                Scenario(name: "tray · Focus") { d in d.startMusic(); d.openTray(at: .focus) },
                Scenario(name: "tray · Timer") { d in d.openTray(at: .timer) },
                Scenario(name: "tray · Clipboard") { d in
                    for t in ["rgba(125, 122, 255, 0.28)", "https://developer.apple.com/design", "Design review moved to 15:30"] { d.tray.addClip(t) }
                    d.startMusic(); d.openTray(at: .clipboard)
                },
                Scenario(name: "tray · Shelf") { d in
                    let root = URL(fileURLWithPath: devFile()).deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().deletingLastPathComponent()
                    d.tray.addFiles(["README.md", "Package.swift", "sim/assets/tracks/espresso.jpg"].map { root.appendingPathComponent($0) })
                    d.startMusic(); d.openTray(at: .shelf)
                },
                Scenario(name: "tray · Shelf, empty") { d in d.openTray(at: .shelf) },
                // Calendar (11-12): an event's ball peeks; a click on its card opens your day.
                Scenario(name: "calendar · the event's ball peeks") { d in
                    d.startMusic(); sampleClass(d); d.pointerMoved(hit: .bubble(0), corridor: false, buttonDown: false)
                },
                Scenario(name: "calendar · your day") { d in sampleDay(d); sampleClass(d); d.openDay() },
                Scenario(name: "calendar · your day, free now") { d in sampleDay(d, free: true); d.openDay() },
                Scenario(name: "media · player, shuffle on") { d in d.startMusic(); d.pointerDown(at: .zero, hit: .ears); d.toggleShuffle() },
            ]
            return list
        }

        /// A real-feed state with a cover from the sim's samples (read from the repo, never bundled).
        @MainActor static func readmeSong() -> NowPlaying { sampleSong() }

        @MainActor private static func sampleSong() -> NowPlaying {
            let cover = URL(fileURLWithPath: devFile()).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("sim/assets/tracks/blinding-lights.jpg")
            return NowPlaying(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours",
                              bundleID: "com.spotify.client", playing: true, duration: 200, elapsed: 64,
                              timestamp: Date(), artwork: try? Data(contentsOf: cover))
        }

        /// Gives the clocks something to show.
        @MainActor private static func advance(_ d: IslandDirector, _ id: ActivityID) {
            if id == .match {
                // Past half time (1–1, two goals scored), the goal moments gone: the match at 50'.
                SnapshotClock.time += 60; d.tick(); SnapshotClock.time += 10; d.tick()
                for g in d.island.running where g.id == .goal { d.end(serial: g.serial) }
                return
            }
            guard SampleState.ticks(id) else { return }
            SnapshotClock.time += id == .download ? 4 : 47
            d.tick()
        }
    }

    // MARK: - Stage

    @MainActor
    final class Stage {
        let renderer: LiquidRenderer
        let notchHalfWidth: Double
        let notchHeight: Double
        let tuning: Tuning
        let view: SIMD2<Double>

        init(renderer: LiquidRenderer, notchHalfWidth: Double, notchHeight: Double, tuning: Tuning) {
            self.renderer = renderer
            self.notchHalfWidth = notchHalfWidth
            self.notchHeight = notchHeight
            self.tuning = tuning
            view = SIMD2(Double(NotchSurfaceController.panelSize.width), Double(NotchSurfaceController.panelSize.height))
        }

        /// A director whose timers never fire and whose clock only moves when told.
        func director() -> IslandDirector {
            let d = IslandDirector()
            SnapshotClock.time = 0
            d.clock = { SnapshotClock.time }
            d.schedule = { _, _ in Scheduled() }
            d.random = { 0.5 }
            d.reduceMotion = { true }
            // README shots (`LN_SNAP_README=1`) play a real song with its cover wherever a state starts the sample music.
            if ProcessInfo.processInfo.environment["LN_SNAP_README"] != nil { d.snapshotSong = Scenario.readmeSong() }
            return d
        }

        /// The surface's view of a director: shape context and mode.
        func targets(for d: IslandDirector) -> (ShapeTargets, PresentationMode) {
            var c = TargetContext()
            let island = d.island
            c.pressed = d.pressed
            c.drag = d.drag
            c.auraHex = d.auraHex
            c.bubbleModes = Set(PresentationMode.allCases.filter { island.hasBubble($0) })
            c.leftBallModes = Set(PresentationMode.allCases.filter { island.balls($0)[1] != nil })
            c.moreModes = Set(PresentationMode.allCases.filter { island.balls($0)[2] != nil })
            c.activityHoldsEars = island.earsHeld
            c.activityEar = island.heldEar
            c.idleHover = d.idleHover
            c.peekPlace = d.groups.peekPlace
            c.peekCard = c.peekPlace.flatMap { d.groups.balls[$0] }.map(Island.peekCard)
            c.card = island.cardSize(player: CardSize(width: tuning.cardHalfWidth * 2, height: tuning.cardHeight,
                                                      radius: tuning.cardRadius))
            return (ShapeTargets(notchHalfWidth: notchHalfWidth, notchHeight: notchHeight, tuning: tuning, context: c), d.mode)
        }

        func animator(_ t: ShapeTargets, _ mode: PresentationMode) -> ShapeAnimator {
            let a = ShapeAnimator(initial: t.resting(mode), configs: tuning.springs, dynamics: tuning.dynamics)
            a.floor = (notchHalfWidth, notchHeight)
            a.cardBridge = (tuning.cardNeckMax, tuning.cardBreakGap)
            a.snap(to: t.resting(mode))
            return a
        }

        func image(_ frame: ShapeFrame, targets t: ShapeTargets, mode: PresentationMode, region: Region,
                   content d: IslandDirector?, xray: Bool = false) -> CGImage? {
            let f = t.drawn(frame)
            let n = t.notchConstants
            let constants = SurfaceConstants(viewSize: view, scale: scale, notchHalfWidth: n.halfWidth, notchHeight: n.height,
                                             notchRadius: n.radius, cornerExponent: tuning.cornerExponent,
                                             kNotch: tuning.kNotch, kDrop: tuning.kDrop, edgeFeather: tuning.edgeFeather,
                                             fill: xray ? SIMD3(0.55, 0.06, 0.12) : .zero)
            let u = ShapeUniforms(state: f.state, neckRadius: f.neckRadius, dropRadii: f.dropRadii, constants: constants,
                                  extras: FrameExtras(cardNeck: f.cardNeck, earGlowOffset: mode == .card ? 8 : 0))
            let w = Int(view.x * scale), h = Int(view.y * scale)
            let px = renderer.renderOffscreen(width: w, height: h, uniforms: u)
            guard let base = composite(px, width: w, height: h, region: region,
                                       notchHalfWidth: notchHalfWidth, notchHeight: notchHeight, xray: xray)
            else { return nil }
            guard let d else { return base }

            let model = NotchContentModel()
            model.groups = d.groups
            model.mode = mode
            model.card = t.card
            model.cardIsPlayer = NotchContentModel.artRidesCard(mode: mode, groups: d.groups, was: d.island.cardOwner == .media)
            model.playerWidth = tuning.cardHalfWidth * 2
            model.playerHeight = tuning.cardHeight
            model.stills = true                // entrances finished, nothing looping or fading
            let fm = FrameModel()
            fm.notchHalfWidth = notchHalfWidth
            fm.notchHeight = notchHeight
            fm.peekHeight = tuning.peekHeight
            fm.expandedHeight = tuning.expandedHeight
            fm.bubbleRadius = tuning.dropRadius
            fm.update(f)
            let r = ImageRenderer(content: NotchContentView(model: model, frame: fm, director: d).id(UUID()))
            r.scale = scale
            let overlay = r.cgImage
            // ImageRenderer can carry a layer of the previous still into the next one; an empty
            // render in between flushes it.
            _ = ImageRenderer(content: Color.clear.frame(width: 1, height: 1)).cgImage
            guard let overlay,
                  let c = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
            c.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            let x0 = Double(w - base.width) / 2
            // CG origin is bottom-left: the overlay's top row must sit on the image's top row.
            c.draw(overlay, in: CGRect(x: -x0, y: Double(base.height - overlay.height),
                                       width: Double(overlay.width), height: Double(overlay.height)))
            return c.makeImage()
        }
    }

    // MARK: - Images

    /// Premultiplied BGRA over a fake menu bar + desktop, cropped around the notch.
    private static func composite(_ px: [UInt8], width: Int, height: Int, region: Region,
                                  notchHalfWidth: Double, notchHeight: Double, xray: Bool) -> CGImage? {
        let cw = Int(region.width * scale), ch = Int(region.height * scale)
        let x0 = (width - cw) / 2
        let menuBar = notchHeight * scale
        let cx = Double(width) / 2
        let readme = ProcessInfo.processInfo.environment["LN_SNAP_README"] != nil
        var out = [UInt8](repeating: 255, count: cw * ch * 4)   // RGBA
        for y in 0..<ch {
            for x in 0..<cw {
                let sx = x + x0
                let fx = Double(sx) + 0.5, fy = Double(y) + 0.5
                // Background: light menu bar over a blue desktop; for README shots (`LN_SNAP_README=1`) a pale sky.
                var bg: SIMD3<Double> = fy < menuBar ? SIMD3(0.86, 0.86, 0.87) : SIMD3(0.23, 0.39, 0.58)
                if readme {
                    // Calm, like the video's "day" wallpaper: a light menu bar over a pale sky, so the island is what you see.
                    let v = fy / Double(ch)
                    let sky = SIMD3(0.74, 0.85, 0.93) * (1 - v) + SIMD3(0.89, 0.92, 0.94) * v
                    bg = fy < menuBar ? SIMD3(0.93, 0.94, 0.96) : sky
                }
                let inNotch = abs(fx - cx) < notchHalfWidth * scale && fy < notchHeight * scale
                if inNotch && !xray { bg = .zero }
                let i = (y * width + sx) * 4
                let b = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, r = Double(px[i + 2]) / 255
                let a = Double(px[i + 3]) / 255
                var c = SIMD3(r, g, b) + bg * (1 - a)
                if xray {
                    // Hardware notch outline.
                    let edge = abs(abs(fx - cx) - notchHalfWidth * scale) < 0.75 && fy < notchHeight * scale
                        || abs(fy - notchHeight * scale) < 0.75 && abs(fx - cx) < notchHalfWidth * scale
                    if edge { c = SIMD3(1, 1, 1) }
                }
                let o = (y * cw + x) * 4
                out[o] = UInt8(min(max(c.x, 0), 1) * 255)
                out[o + 1] = UInt8(min(max(c.y, 0), 1) * 255)
                out[o + 2] = UInt8(min(max(c.z, 0), 1) * 255)
            }
        }
        return image(out, width: cw, height: ch)
    }

    private static func image(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func grid(_ images: [CGImage], columns: Int) -> CGImage? {
        guard !images.isEmpty else { return nil }
        // Cells fit the largest still; each is drawn at its own size from its cell's top-left.
        let w = images.map(\.width).max()!, h = images.map(\.height).max()!, gap = 6
        let rows = (images.count + columns - 1) / columns
        let W = columns * w + (columns - 1) * gap, H = rows * h + (rows - 1) * gap
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, img) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(img, in: CGRect(x: col * (w + gap), y: H - row * (h + gap) - img.height, width: img.width, height: img.height))
        }
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// The snapshot's clock: moves only when a scenario says so.
@MainActor
enum SnapshotClock {
    static var time = 0.0
}

extension ShapeTargets {
    /// A frame resting at `mode`.
    @MainActor
    func restingFrame(_ mode: PresentationMode) -> ShapeFrame {
        let a = ShapeAnimator(initial: resting(mode), configs: tuning.springs, dynamics: tuning.dynamics)
        a.cardBridge = (tuning.cardNeckMax, tuning.cardBreakGap)
        a.snap(to: resting(mode))
        return a.frame
    }
}

/// Quick ask in stills: no processes, no screen capture.
@MainActor private func askStub(_ d: IslandDirector) {
    d.askSend = { _, _, _, _ in }
    d.screenAllowed = { true }
    d.captureScreen = { nil }
}

/// A hook call as the socket would hand it over, for the agents' stills (an approval is held, unanswered).
@MainActor
private func agent(_ d: IslandDirector, _ event: String, _ id: String = "c1", _ provider: AgentProvider = .claude,
                   tool: String = "", extra: String = "") {
    d.frontmostApp = { "" }
    let input = tool == "AskUserQuestion"
        ? #"{"questions":[{"question":"Port the tray's Ask tool now or after the chat card?","options":[{"label":"Now"},{"label":"After"}]}]}"#
        : #"{"command":"swift test --filter AgentHookTests"}"#
    let json = #"{"session_id":"\#(id)","cwd":"/Users/f/Developer/\#(provider == .claude ? "liquid-notch" : "mac-suite")","tool_name":"\#(tool)","tool_input":\#(input)\#(extra)}"#
    let line = AgentSocket.Line(provider: provider.rawValue, event: event, host: "", raw: Data(json.utf8))
    d.agentHook(line, reply: event == "PermissionRequest" ? { _ in } : nil)
}

/// A session's chat and title as its transcript and the Claude app would give them, for the agents' stills.
@MainActor
private func sampleChat(_ d: IslandDirector, _ id: String = "c1") {
    d.agentTitles[id] = "Liquid Notch: ball peek"
    d.agentTitles["c2"] = "Lid: hinge sound"
    d.agentChats[id] = [
        .you("The ball should peek on its own when I hover it"),
        .agent("On it. The peek hangs under the ball and the ears stay where they are."),
        .tools("Ran 3 commands · edited 2 files", ["$ swift build", "Edited Island.swift", "Edited ShapeTargets.swift",
                                                    "$ swift test --filter AgentChatTests", "$ swift build"]),
        .agent("Done: hovering a ball swells it and shows its peek; a **click** opens its chat."),
    ]
}

/// A day of events around now: one all day, one past, one on now, two to come (`free`: nothing on now).
@MainActor private func sampleDay(_ d: IslandDirector, free: Bool = false) {
    let n = d.date(), h = 3600.0
    var items = [
        AgendaItem(id: "d0", title: "Mom's birthday", start: n.addingTimeInterval(-10 * h), end: n.addingTimeInterval(10 * h),
                   allDay: true, calendar: "Family", colorHex: "#FF9F0A"),
        AgendaItem(id: "d1", title: "Calculus II", start: n.addingTimeInterval(-2 * h), end: n.addingTimeInterval(-h),
                   allDay: false, calendar: "School", colorHex: "#30D158"),
        AgendaItem(id: "d3", title: "Lunch", start: n.addingTimeInterval(1.5 * h), end: n.addingTimeInterval(2.5 * h),
                   allDay: false, calendar: "Personal", colorHex: "#BF5AF2"),
        AgendaItem(id: "d4", title: "Design review", start: n.addingTimeInterval(4 * h), end: n.addingTimeInterval(5 * h),
                   allDay: false, calendar: "Work", colorHex: "#0A84FF"),
    ]
    if !free {
        items.insert(AgendaItem(id: "d2", title: "Physics lab", start: n.addingTimeInterval(-1200), end: n.addingTimeInterval(2400),
                                allDay: false, calendar: "School", colorHex: "#30D158"), at: 2)
    }
    d.agendaChanged(items)
}

/// A class that started 20 minutes ago, as the real feed sends it.
@MainActor private func sampleClass(_ d: IslandDirector) {
    let n = d.date()
    d.meetingChanged(MeetingInfo(title: "Physics lab", start: n.addingTimeInterval(-1200), end: n.addingTimeInterval(2400),
                                 joinURL: nil, initials: [], more: 0))
}
