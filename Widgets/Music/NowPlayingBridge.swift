import AppKit
import Foundation

// Bridge to the system Now Playing. Can't read it directly: since macOS 15.4
// mediaremoted only answers processes with a com.apple.* bundle id. So a
// helper library is loaded by the system /usr/bin/perl, which has the needed
// entitlement, and it prints JSON back to us.
// The process lives only while the panel has been open; close it and nothing
// is left running in the background.

struct NowPlayingTrack: Sendable, Equatable {
    var title: String
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double?
    var rate: Double?
    var artwork: Data?
    var isPlaying: Bool
    // Moment `elapsed` refers to, reported by the player itself. Can't count
    // from delivery time: the notification can arrive whenever, and the
    // scrubber would get stuck at the start while the song had already been
    // playing for a minute
    var timestamp: Date?
    // When the message reached us — fallback reference point if the player gave none
    var stamp: Date = .now
    /// Player process. Tells us the source has closed: the event comes from
    /// NSWorkspace, no need to ask anyone about it
    var sourcePID: Int32?

    // How much has played now — elapsed plus time passed since the reference point
    func position(at now: Date) -> Double? {
        guard let elapsed else { return nil }
        guard isPlaying else { return elapsed }
        let base = timestamp ?? stamp
        let value = elapsed + now.timeIntervalSince(base) * (rate ?? 1)
        guard let duration else { return max(value, 0) }
        return min(max(value, 0), duration)
    }
}

enum NowPlayingCommand: String {
    case toggle, play, pause, next, prev
}

// One source for all tiles of the widget: three music tiles on the board are
// still one helper process and one subscription. The bridge comes up on the
// first tile that wakes and goes down with the last one that sleeps
@MainActor @Observable
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private(set) var track: NowPlayingTrack?

    // MARK: - music or video

    /// MediaRemote doesn't report a media type (its dictionary has no such
    /// key — checked against a live dump), so the capsule guesses from the
    /// source app: browsers and video players get a film icon, everything
    /// else stays a note. A browser playing YouTube Music will read as
    /// video — the source can't tell us more
    private static let videoBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "org.chromium.Chromium",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "net.imput.helium",
        "org.videolan.vlc", "com.colliderli.iina", "com.apple.QuickTimePlayerX",
        "com.apple.TV", "io.mpv", "org.niltsh.MPlayerX", "com.eltima.elmedia",
        "tv.kodi.kodi", "com.movist.Movist", "com.firecore.infuse",
    ]

    /// Cached per pid: resolving NSRunningApplication on every island tick
    /// would be wasted work for an answer that never changes for a process
    @ObservationIgnored private var videoSourceCache: [pid_t: Bool] = [:]

    func sourceLooksLikeVideo(_ track: NowPlayingTrack) -> Bool {
        guard let pid = track.sourcePID else { return false }
        if let cached = videoSourceCache[pid] { return cached }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let isVideo = bundleID.map { Self.videoBundleIDs.contains($0) } ?? false
        videoSourceCache[pid] = isVideo
        return isVideo
    }

    /// State changed. The notch capsule subscribes here and updates
    /// immediately, rather than on its own tick — otherwise pause took a
    /// couple of seconds to reach it
    @ObservationIgnored var onChange: (() -> Void)?
    private(set) var failure: String?
    // A moment passes between pressing next/prev and the new track arriving.
    // The tile dims for that time: visible confirmation that the command was
    // received and a change is underway
    private(set) var isSwitching = false

    @ObservationIgnored private var bridge: NowPlayingBridge?
    @ObservationIgnored private var subscribers: Set<UUID> = []
    @ObservationIgnored private var backgroundOnly: Set<UUID> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private var exitObserver: NSObjectProtocol?

    private init() {}

    /// `background: true` — a subscriber that lives while the panel is closed
    /// (the notch capsule). While it's the only one, we poll noticeably less
    /// often: the app has to stay nearly free in the background
    func subscribe(_ id: UUID, background: Bool = false) {
        subscribers.insert(id)
        if background { backgroundOnly.insert(id) } else { backgroundOnly.remove(id) }
        guard bridge == nil else { return }
        let bridge = NowPlayingBridge(
            onUpdate: { [weak self] track in
                self?.accept(track)
                self?.failure = nil
            },
            onFailure: { [weak self] message in
                self?.failure = message
            })
        self.bridge = bridge
        bridge.start()
        watchSourceExit()
        startPolling()
    }

    // The main "gone" case is the player being closed. There's a real event
    // for it, just not from MediaRemote — from the system: NSWorkspace reports
    // the process terminating, and the helper gives us the source's pid.
    // A match means the state is stale
    private func watchSourceExit() {
        guard exitObserver == nil else { return }
        exitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            Task { @MainActor in
                guard let self, let pid, pid == self.track?.sourcePID else { return }
                self.bridge?.refresh()
            }
        }
    }

    // MediaRemote notifications are the only event source, and they get lost:
    // player closed, the daemon restarted, a track ended in a minimized
    // window — no message may arrive at all. Confirmed live: the system
    // showed "Not Playing" while the tile still showed a track with a moving
    // scrubber. So we poll ourselves as a backstop
    private static let pollInterval: TimeInterval = 5
    private static let backgroundPollInterval: TimeInterval = 30

    /// Panel is open if anyone besides the capsule is subscribed
    private var isForeground: Bool { !subscribers.subtracting(backgroundOnly).isEmpty }

    // Backstop for a lost event: the daemon restarted, or the player stopped
    // publishing without closing. Only poll while holding a track — nothing
    // to show means nothing to go stale, so no need to poll at all
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.isForeground == false
                    ? Self.backgroundPollInterval
                    : Self.pollInterval
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard track != nil else { continue }
                bridge?.refresh()
            }
        }
    }

    func unsubscribe(_ id: UUID) {
        subscribers.remove(id)
        backgroundOnly.remove(id)
        guard subscribers.isEmpty else { return }
        pollTask?.cancel()
        pollTask = nil
        switchTask?.cancel()
        switchTask = nil
        if let exitObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(exitObserver)
        }
        exitObserver = nil
        emptyCheck?.cancel()
        emptyCheck = nil
        emptySince = nil
        waitingTask?.cancel()
        waitingTask = nil
        waiting = nil
        bridge?.stop()
        bridge = nil
        track = nil
        failure = nil
    }

    func send(_ command: NowPlayingCommand) {
        // The player doesn't answer instantly, and manages to send a message
        // or two about the old state first. Suppress those, otherwise the
        // track "jumps back" for a split second
        let deadline = Date().addingTimeInterval(Self.echoWindow)
        switch command {
        case .next, .prev:
            if let title = track?.title { pendingSkip = (title, deadline) }
            isSwitching = true
            // If the player never answers at all (closed mid-gesture), the
            // tile would otherwise stay dimmed forever
            switchTask?.cancel()
            switchTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.echoWindow))
                guard let self, !Task.isCancelled else { return }
                isSwitching = false
                pendingSkip = nil
                bridge?.refresh()
            }
        case .toggle:
            if let playing = track?.isPlaying { pendingPlayback = (!playing, deadline) }
        case .play:
            pendingPlayback = (true, deadline)
        case .pause:
            pendingPlayback = (false, deadline)
        }
        bridge?.send(command)
    }

    func seek(to seconds: Double) {
        pendingSeek = (seconds, Date().addingTimeInterval(Self.echoWindow))
        bridge?.seek(to: seconds)
    }

    // Local response to a press: pause shows immediately, confirmation follows from the helper
    func applyOptimistic(_ track: NowPlayingTrack?) { self.track = track }

    // How long we wait for the player to catch up with a command. Any longer,
    // and a real position change from the player itself (person scrubbed
    // inside the app) would start getting lost
    private static let echoWindow: TimeInterval = 1.2
    // How close the position must land to the requested one to count the seek as accepted
    private static let seekTolerance: Double = 2.5

    @ObservationIgnored private var pendingSeek: (target: Double, until: Date)?
    @ObservationIgnored private var pendingSkip: (title: String, until: Date)?
    @ObservationIgnored private var pendingPlayback: (playing: Bool, until: Date)?
    // When the player first said "nothing playing" — wait, in case it's just between tracks
    @ObservationIgnored private var emptySince: Date?
    @ObservationIgnored private var emptyCheck: Task<Void, Never>?
    private static let emptyGrace: TimeInterval = 1.5

    private func scheduleEmptyCheck() {
        guard emptyCheck == nil else { return }
        emptyCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.emptyGrace))
            guard let self else { return }
            emptyCheck = nil
            guard let since = emptySince, Date().timeIntervalSince(since) >= Self.emptyGrace else {
                return
            }
            emptySince = nil
            pendingSeek = nil
            pendingSkip = nil
            pendingPlayback = nil
            waiting = nil
            waitingTask?.cancel()
            waitingTask = nil
            isSwitching = false
            track = nil
            onChange?()
        }
    }

    // Message from the helper: part of the data may belong to the state
    // before our command. Each pending wait is tracked separately and clears
    // as soon as the player catches up — or when its window expires, so a
    // correction from the player itself isn't lost for good
    private func accept(_ incoming: NowPlayingTrack?) {
        let now = Date()
        guard var value = incoming else {
            // "Nothing playing" between tracks — the player blinks empty for
            // a fraction of a second. Only trust the emptiness if it holds:
            // otherwise the tile would flash the placeholder on every skip.
            // A track waiting on its artwork still counts as a track: without
            // this check, an empty message arriving during that wait would be
            // skipped, and the wait would then apply a track that no longer exists
            guard track != nil || waiting != nil else { return }
            emptySince = emptySince ?? now
            scheduleEmptyCheck()
            return
        }
        emptySince = nil

        if let skip = pendingSkip {
            // "Previous" in the first few seconds of a track replays it from
            // the start: same title, but position jumped to zero — that's
            // already a new state, not an echo of the old one
            let restarted = (value.elapsed ?? 0) + 2 < (track?.position(at: now) ?? 0)
            if now >= skip.until || restarted {
                pendingSkip = nil
            } else if value.title == skip.title {
                return  // still the old track — the player hasn't switched yet
            } else {
                // New track arrived: earlier pending waits no longer apply to it
                pendingSkip = nil
                pendingSeek = nil
                pendingPlayback = nil
            }
        }

        if let playback = pendingPlayback {
            if value.isPlaying == playback.playing || now >= playback.until {
                pendingPlayback = nil
            } else {
                // The button already shows the new state — don't flicker back
                // to the old one. Keep our own position too: the player sends
                // it with its own rounding, and the scrubber jittered on every pause
                value.isPlaying = playback.playing
                value.elapsed = track?.elapsed
                value.timestamp = track?.timestamp
                value.stamp = track?.stamp ?? value.stamp
            }
        }

        if let seek = pendingSeek {
            let landed = value.elapsed.map { abs($0 - seek.target) < Self.seekTolerance } ?? false
            if landed || now >= seek.until {
                pendingSeek = nil
            } else {
                // Keep our own position, accept everything else (pause, artwork, track)
                value.elapsed = track?.elapsed
                value.timestamp = track?.timestamp
                value.stamp = track?.stamp ?? value.stamp
            }
        }

        // Same track — don't lose artwork on intermediate messages
        let sameTrack = track.map { $0.title == value.title && $0.artist == value.artist } ?? false
        if sameTrack, value.artwork == nil {
            value.artwork = track?.artwork
        }

        // A new track is shown whole. Title, artist, and artwork arrive as
        // separate messages, and without this wait the tile assembled itself
        // piece by piece in front of the person
        if !sameTrack, value.artwork == nil {
            waiting = value
            scheduleWaitingApply()
            return
        }
        waiting = nil
        waitingTask?.cancel()
        waitingTask = nil

        track = value
        isSwitching = false
        onChange?()
    }

    // Track waiting on its artwork: the helper fetches it by polling and
    // sends it once it's available. The cap only matters when there's no
    // image at all — the track then shows without one, instead of hanging forever
    @ObservationIgnored private var waiting: NowPlayingTrack?
    @ObservationIgnored private var waitingTask: Task<Void, Never>?
    // Wait for artwork exactly long enough that the track doesn't visibly
    // assemble piece by piece. Used to be four seconds — that looked like
    // "the player is lagging": the track itself had already changed while the
    // tile still showed the old one. Measured: artwork arrives in hundredths
    // of a second, so a third of a second is generous
    private static let artworkGrace: TimeInterval = 0.35

    private func scheduleWaitingApply() {
        guard waitingTask == nil else { return }
        waitingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.artworkGrace))
            guard let self else { return }
            waitingTask = nil
            guard let pending = waiting else { return }
            waiting = nil
            track = pending
            isSwitching = false
            onChange?()
        }
    }
}

@MainActor
final class NowPlayingBridge {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    // Artwork arrives once per track, kept here after that
    private var lastArtwork: Data?
    private var lastKey: String?
    private let onUpdate: @MainActor (NowPlayingTrack?) -> Void
    private let onFailure: @MainActor (String) -> Void

    // The library sits in the bundle next to the frameworks
    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Frameworks/nowplaying.dylib")
    }

    init(
        onUpdate: @escaping @MainActor (NowPlayingTrack?) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.onUpdate = onUpdate
        self.onFailure = onFailure
    }

    func start() {
        guard process == nil else { return }
        let helper = Self.helperURL
        guard FileManager.default.fileExists(atPath: helper.path) else {
            onFailure(String(localized: "Couldn't read what's playing"))
            return
        }

        // perl loads the library and just sleeps: all the work happens in its constructor
        let script = """
            use DynaLoader;
            DynaLoader::dl_load_file("\(helper.path)", 0x01);
            1 while sleep 3600;
            """
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/perl")
        task.arguments = ["-e", script]

        let output = Pipe()
        let commands = Pipe()
        task.standardOutput = output
        task.standardInput = commands
        let errors = Pipe()
        task.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            sillLog("[music] stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // The handler arrives on its own queue — enter MainActor explicitly
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }

        task.terminationHandler = { finished in
            let reason = finished.terminationReason == .uncaughtSignal ? "signal" : "exit"
            sillLog("[music] helper terminated: \(reason) \(finished.terminationStatus)")
        }
        do {
            try task.run()
        } catch {
            onFailure(String(localized: "perl didn't start: \(error.localizedDescription)"))
            return
        }
        sillLog("[music] helper started, pid \(task.processIdentifier)")
        process = task
        input = commands.fileHandleForWriting
    }

    func stop() {
        process?.terminationHandler = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // stderr too: on a closed pipe the handler fires on EOF and holds the
        // pipe open. This accumulated one per "opened the panel with music —
        // closed it" cycle
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        buffer.removeAll()
    }

    func send(_ command: NowPlayingCommand) {
        write(command.rawValue)
    }

    /// Ask again for the current state: notifications get lost, and without
    /// this the tile is left holding a track that ended long ago
    func refresh() {
        write("refresh")
    }

    // Seeking is a position set, not a command — MediaRemote treats them as different calls
    func seek(to seconds: Double) {
        write(String(format: "seek %.2f", max(seconds, 0)))
    }

    private func write(_ line: String) {
        guard let input, let data = (line + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    // The helper prints one line of JSON per event; a line may arrive in pieces
    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let error = json["error"] as? String {
            onFailure(error)
            return
        }
        guard json["empty"] == nil, let title = json["title"] as? String else {
            lastKey = nil
            lastArtwork = nil
            onUpdate(nil)
            return
        }
        // The helper sends artwork only on a track change — on other messages
        // (pause, seek) we keep the previous one, otherwise the image would flicker
        let album = json["album"] as? String
        let key = "\(title)|\(album ?? "")"
        if let encoded = json["artwork"] as? String {
            lastArtwork = Data(base64Encoded: encoded)
        } else if key != lastKey {
            lastArtwork = nil
        }
        lastKey = key

        onUpdate(
            NowPlayingTrack(
                title: title,
                artist: json["artist"] as? String,
                album: album,
                duration: json["duration"] as? Double,
                elapsed: json["elapsed"] as? Double,
                rate: json["rate"] as? Double,
                artwork: lastArtwork,
                isPlaying: json["playing"] as? Bool ?? false,
                timestamp: (json["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) },
                sourcePID: (json["pid"] as? Int).map(Int32.init)))
    }
}
