// Jukebox helper: listens for `jukebox_command` events from Home Assistant
// and plays albums from the Music library on AirPlay speakers (HomePods).
//
//   jukebox serve                 connect to Home Assistant and wait for commands
//   jukebox card "<card name>"    run one card by hand, e.g. "Frayed At Both Ends @ Office"
//   jukebox rooms                 list the AirPlay speakers Music can see

import Foundation

// MARK: - Logging

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withInternetDateTime])
    print("\(stamp) \(message)")
    fflush(stdout)
}

struct JukeboxError: Error { let message: String }

// MARK: - Config

struct Config: Codable {
    var haURL = "http://homeassistant.local:8123"
    var defaultRoom = "Theater Room"
    var startVolume = 35
    var volumeStep = 5
    var keychainService = "jukebox-ha-token"

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Jukebox")
    static let file = dir.appendingPathComponent("config.json")

    static func load() -> Config {
        if let data = try? Data(contentsOf: file),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        let cfg = Config()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(cfg).write(to: file)
        return cfg
    }

    func token() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !token.isEmpty else {
            throw JukeboxError(message: "No Home Assistant token in the Keychain (service \"\(keychainService)\").")
        }
        return token
    }
}

// MARK: - Cards

enum Card {
    case album(name: String, artist: String?, room: String?)
    case control(String)

    // "Album", "Album | Artist", "Album @ Room", "Album | Artist @ Room", "Jukebox: Stop"
    static func parse(_ raw: String) -> Card {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("jukebox:") {
            let cmd = text.dropFirst("jukebox:".count)
            return .control(cmd.trimmingCharacters(in: .whitespaces).lowercased())
        }
        var room: String?
        if let r = text.range(of: " @ ", options: .backwards) {
            room = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            text = String(text[..<r.lowerBound])
        }
        var artist: String?
        if let r = text.range(of: " | ", options: .backwards) {
            artist = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            text = String(text[..<r.lowerBound])
        }
        return .album(name: text.trimmingCharacters(in: .whitespaces), artist: artist, room: room)
    }
}

// MARK: - Music app

final class Music {
    let config: Config
    init(config: Config) { self.config = config }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @discardableResult
    func run(_ body: String) throws -> NSAppleEventDescriptor {
        let source = "tell application \"Music\"\n\(body)\nend tell"
        guard let script = NSAppleScript(source: source) else {
            throw JukeboxError(message: "Could not build AppleScript.")
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err = err {
            throw JukeboxError(message: "Music app error: \(err[NSAppleScript.errorMessage] ?? err)")
        }
        return result
    }

    static func items(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        d.numberOfItems == 0 ? [] : (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    func rooms() throws -> [String] {
        Music.items(try run("return name of every AirPlay device")).compactMap { $0.stringValue }
    }

    func perform(_ card: Card) throws -> String {
        switch card {
        case let .album(name, artist, room):
            return try playAlbum(name, artist: artist, room: room)
        case let .control(cmd):
            return try control(cmd)
        }
    }

    private struct Track {
        let id: Int32, disc: Int32, number: Int32
        let album: String, albumArtist: String
    }

    private func findTracks(_ album: String, match: String) throws -> [Track] {
        let d = try run("""
            try
                return {database ID, disc number, track number, album, album artist} of (every track of library playlist 1 whose album \(match) \(Music.quote(album)))
            on error
                return {}
            end try
            """)
        let cols = Music.items(d).map(Music.items)
        guard cols.count == 5 else { return [] }
        return (0..<cols[0].count).map { i in
            Track(id: cols[0][i].int32Value, disc: cols[1][i].int32Value, number: cols[2][i].int32Value,
                  album: cols[3][i].stringValue ?? "", albumArtist: cols[4][i].stringValue ?? "")
        }
    }

    private func playAlbum(_ name: String, artist: String?, room: String?) throws -> String {
        // Exact album title first, then fall back to "contains" (e.g. deluxe editions).
        var tracks = try findTracks(name, match: "is")
        if tracks.isEmpty { tracks = try findTracks(name, match: "contains") }
        if let artist = artist {
            tracks = tracks.filter { $0.albumArtist.localizedCaseInsensitiveContains(artist) }
        }
        // Several albums can share a title; keep the biggest one.
        let groups = Dictionary(grouping: tracks) { "\($0.album)\u{1F}\($0.albumArtist)" }
        guard let best = groups.values.max(by: { $0.count < $1.count }), let first = best.first else {
            let who = artist.map { " by \($0)" } ?? ""
            throw JukeboxError(message: "\"\(name)\"\(who) isn't in your Music library. Add the album to your library in the Music app, then scan again.")
        }
        var seen = Set<String>()
        let ordered = best
            .sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
            .filter { seen.insert("\($0.disc)-\($0.number)").inserted }

        let speaker = try resolveRoom(room ?? config.defaultRoom)
        let ids = ordered.map { String($0.id) }.joined(separator: ", ")
        try run("""
            stop
            if not (exists user playlist "Jukebox") then make new user playlist with properties {name:"Jukebox"}
            set jp to user playlist "Jukebox"
            delete every track of jp
            repeat with i in {\(ids)}
                duplicate (some track of library playlist 1 whose database ID is (contents of i)) to jp
            end repeat
            set target to AirPlay device \(Music.quote(speaker))
            set selected of target to true
            repeat with n in (get name of every AirPlay device whose selected is true)
                if (contents of n) is not \(Music.quote(speaker)) then set selected of AirPlay device (contents of n) to false
            end repeat
            set sound volume of target to \(config.startVolume)
            set shuffle enabled to false
            set song repeat to off
            play jp
            """)
        let by = first.albumArtist.isEmpty ? "" : " by \(first.albumArtist)"
        return "Playing \(first.album)\(by) (\(ordered.count) tracks) on \(speaker)"
    }

    private func resolveRoom(_ wanted: String) throws -> String {
        let all = try rooms()
        if let hit = all.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return hit }
        throw JukeboxError(message: "No AirPlay speaker named \"\(wanted)\". Speakers: \(all.joined(separator: ", ")).")
    }

    private func adjustVolume(_ delta: Int) -> String {
        """
        repeat with n in (get name of every AirPlay device whose selected is true)
            set d to AirPlay device (contents of n)
            set v to (sound volume of d) + (\(delta))
            if v < 0 then set v to 0
            if v > 100 then set v to 100
            set sound volume of d to v
        end repeat
        """
    }

    private func control(_ cmd: String) throws -> String {
        let step = config.volumeStep
        // Stop also hands Music back to the Mac's own speaker, so everyday listening isn't stuck on the HomePods.
        let stopAndReset = """
            stop
            set macSpeaker to (first AirPlay device whose kind is computer)
            set macName to name of macSpeaker
            set selected of macSpeaker to true
            repeat with n in (get name of every AirPlay device whose selected is true)
                if (contents of n) is not macName then set selected of AirPlay device (contents of n) to false
            end repeat
            """
        let scripts: [String: String] = [
            "stop": stopAndReset,
            "pause": "pause",
            "play": "play",
            "resume": "play",
            "play/pause": "playpause",
            "next": "next track",
            "skip": "next track",
            "previous": "back track",
            "back": "back track",
            "volume up": adjustVolume(step),
            "volume down": adjustVolume(-step),
        ]
        if cmd.hasPrefix("volume "), let n = Int(cmd.dropFirst("volume ".count)) {
            try run("repeat with n in (get name of every AirPlay device whose selected is true)\nset sound volume of AirPlay device (contents of n) to \(max(0, min(100, n)))\nend repeat")
            return "Volume set to \(n)"
        }
        guard let body = scripts[cmd] else {
            throw JukeboxError(message: "Unknown jukebox control \"\(cmd)\". Try: \(scripts.keys.sorted().joined(separator: ", ")), volume <0-100>.")
        }
        try run(body)
        return "Did \(cmd)"
    }
}

// MARK: - Home Assistant WebSocket client

final class HomeAssistant: NSObject {
    let url: URL
    let token: String
    var onCommand: (([String: Any]) -> Void)?

    private lazy var session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private var backoff = 1.0
    private var pingTimer: DispatchSourceTimer?

    init(baseURL: String, token: String) {
        var s = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://") { s = "ws://" + s.dropFirst(7) }
        self.url = URL(string: s + "/api/websocket")!
        self.token = token
    }

    func start() {
        connect()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.ping() }
        t.resume()
        pingTimer = t
    }

    private func connect() {
        log("Connecting to \(url)")
        let ws = session.webSocketTask(with: url)
        ws.maximumMessageSize = 16 * 1024 * 1024
        task = ws
        ws.resume()
        receive(on: ws)
    }

    private func receive(on ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self = self, ws === self.task else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(text)
                self.receive(on: ws)
            case .success(.data(let data)):
                self.handle(String(decoding: data, as: UTF8.self))
                self.receive(on: ws)
            case .success:
                self.receive(on: ws)
            case .failure(let error):
                self.reconnect(ws, reason: error.localizedDescription)
            }
        }
    }

    private func reconnect(_ ws: URLSessionWebSocketTask, reason: String) {
        guard ws === task else { return }
        task = nil
        pending.removeAll()
        ws.cancel(with: .goingAway, reason: nil)
        log("Disconnected (\(reason)); retrying in \(Int(backoff))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in self?.connect() }
        backoff = min(backoff * 2, 60)
    }

    private func ping() {
        guard let ws = task else { return }
        ws.sendPing { [weak self] error in
            if let error = error {
                DispatchQueue.main.async { self?.reconnect(ws, reason: "ping failed: \(error.localizedDescription)") }
            }
        }
    }

    private func sendRaw(_ msg: [String: Any]) {
        guard let ws = task, let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        ws.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async { self?.reconnect(ws, reason: "send failed: \(error.localizedDescription)") }
            }
        }
    }

    func send(_ msg: [String: Any], reply: (([String: Any]) -> Void)? = nil) {
        var msg = msg
        let id = nextId
        nextId += 1
        msg["id"] = id
        if let reply = reply { pending[id] = reply }
        sendRaw(msg)
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let msg = obj as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "auth_required":
            sendRaw(["type": "auth", "access_token": token])
        case "auth_ok":
            backoff = 1
            log("Connected to Home Assistant \(msg["ha_version"] ?? "")")
            send(["type": "subscribe_events", "event_type": "jukebox_command"]) { reply in
                if reply["success"] as? Bool == true {
                    log("Listening for jukebox_command events")
                } else {
                    log("Could not subscribe to jukebox_command events: \(reply["error"] ?? reply)")
                }
            }
        case "auth_invalid":
            log("Home Assistant rejected the token: \(msg["message"] ?? "")")
            backoff = 60
            if let ws = task { reconnect(ws, reason: "auth_invalid") }
        case "event":
            if let event = msg["event"] as? [String: Any], let data = event["data"] as? [String: Any] {
                onCommand?(data)
            }
        case "result":
            if let id = msg["id"] as? Int, let cb = pending.removeValue(forKey: id) { cb(msg) }
        default:
            break
        }
    }

    func tagName(_ tagId: String, completion: @escaping (String?) -> Void) {
        send(["type": "tag/list"]) { msg in
            let tags = msg["result"] as? [[String: Any]] ?? []
            let tag = tags.first { ($0["id"] as? String) == tagId }
            completion(tag?["name"] as? String)
        }
    }

    func notify(_ message: String) {
        send(["type": "call_service", "domain": "persistent_notification", "service": "create",
              "service_data": ["title": "Jukebox", "message": message, "notification_id": "jukebox"]])
    }
}

// MARK: - Main

let config = Config.load()
let music = Music(config: config)
let args = Array(CommandLine.arguments.dropFirst())

switch args.first ?? "serve" {
case "card":
    do { print(try music.perform(Card.parse(args.dropFirst().joined(separator: " ")))) }
    catch let e as JukeboxError { print("Error: \(e.message)"); exit(1) }
    exit(0)

case "rooms":
    do { print(try music.rooms().joined(separator: "\n")) }
    catch let e as JukeboxError { print("Error: \(e.message)"); exit(1) }
    exit(0)

case "serve":
    let token: String
    do { token = try config.token() } catch let e as JukeboxError { log(e.message); exit(1) }
    // Touch Music once up front so macOS asks for Automation permission now, not on the first scan.
    log("Checking permission to control Music…")
    do { log("Music is reachable; speakers: \(try music.rooms().joined(separator: ", "))") }
    catch let e as JukeboxError { log("Cannot control Music yet: \(e.message)") }

    let ha = HomeAssistant(baseURL: config.haURL, token: token)

    func run(_ card: Card, label: String) {
        do {
            log("\(label): \(try music.perform(card))")
        } catch let e as JukeboxError {
            log("\(label): \(e.message)")
            ha.notify(e.message)
        } catch {
            log("\(label): \(error)")
        }
    }

    ha.onCommand = { data in
        // Home Assistant templates render missing fields as "", so treat empty as absent.
        func text(_ key: String) -> String? {
            let s = (data[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return s.isEmpty ? nil : s
        }
        let action = (text("action") ?? "tag").lowercased()
        log("Received \(action): \(text("name") ?? text("album") ?? text("tag_id") ?? "")")
        switch action {
        case "tag":
            let tagId = text("tag_id") ?? ""
            let handle: (String?) -> Void = { name in
                guard let name = name, !name.isEmpty else {
                    log("Card \(tagId) has no name")
                    ha.notify("A jukebox card was scanned that has no name yet. Name it in Settings → Tags (tag \(tagId)).")
                    return
                }
                run(Card.parse(name), label: "Card \"\(name)\"")
            }
            if let name = text("name") { handle(name) } else { ha.tagName(tagId, completion: handle) }
        case "play":
            let album = text("album") ?? ""
            run(.album(name: album, artist: text("artist"), room: text("room")), label: "Play \"\(album)\"")
        default:
            run(.control(action), label: "Control")
        }
    }
    ha.start()
    log("Jukebox helper running (default room: \(config.defaultRoom))")
    dispatchMain()

default:
    print("usage: jukebox [serve | card \"<card name>\" | rooms]")
    exit(2)
}
