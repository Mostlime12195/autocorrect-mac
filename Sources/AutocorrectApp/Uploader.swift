import Foundation
import KeylimeCore
import os

/// Opt-in upload of word-level correction events ("Share correction data", off by default; docs/upload-schema.md).
///
/// TextLayer hands finished decisions to record(); they're scrubbed (CorrectionEvents.make) and queued as JSON lines in
/// Application Support/Autocorrect/upload/corrections.jsonl, only while sharing is on. Every 6 hours (and a minute after
/// launch) the queue goes to the collection server in batches; sent lines are removed from the file. Pending server
/// deletes ("Delete my uploaded data" that couldn't reach the server) go first, also with sharing off.
final class Uploader {
    static let shared = Uploader()

    private let q = DispatchQueue(label: "ac.upload", qos: .utility)
    private let settings = Settings.shared
    private let log = Logger(subsystem: "dev.mostlime.autocorrect-mac", category: "upload")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var _lastResult = "nothing sent yet"
    private var lastResult: String {
        get { lock.lock(); defer { lock.unlock() }; return _lastResult }
        set { lock.lock(); _lastResult = newValue; lock.unlock() }
    }

    static let maxQueueBytes = 256 * 1024
    static let period: Double = 6 * 3600

    var queueURL: URL {
        let d = Settings.supportDir.appendingPathComponent("upload", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("corrections.jsonl")
    }

    // MARK: queue

    /// a finished decision (any thread). Nothing happens unless sharing is on. context: this field may give sentence
    /// context; it is only used when the "Include sentence context" opt-in is on as well.
    func record(_ d: CorrectionDecision, context: Bool = false) {
        guard settings.shareData, let e = CorrectionEvents.make(d, includeContext: context && settings.shareContext),
              let line = CorrectionEvents.line(e) else { return }
        q.async { self.append(line) }
    }

    /// "Include sentence context" was switched off: take the sentences out of everything still queued
    func dropQueuedContext() {
        q.async {
            let ls = self.readLines()
            let out = ls.map(CorrectionEvents.withoutContext)
            if out != ls { self.writeLines(out) }
        }
    }

    private func readLines() -> [String] {
        guard let s = try? String(contentsOf: queueURL, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func writeLines(_ lines: [String]) {
        if lines.isEmpty { try? FileManager.default.removeItem(at: queueURL); return }
        try? (lines.joined(separator: "\n") + "\n").write(to: queueURL, atomically: true, encoding: .utf8)
    }

    private func append(_ line: String) {
        guard settings.shareData else { return }
        let u = queueURL
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        if size > Self.maxQueueBytes {
            // capped: the oldest half goes
            let ls = readLines()
            writeLines(Array(ls.suffix(ls.count / 2)) + [line])
            return
        }
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        } else {
            try? (line + "\n").write(to: u, atomically: true, encoding: .utf8)
        }
    }

    /// the last n queued events exactly as they will be sent (without sentence context unless that opt-in is on right
    /// now), newest first (for the preview). Reads the file directly (writes are atomic or appends), so the main thread
    /// never waits for an upload in progress.
    func preview(_ n: Int = 20) -> (lines: [String], total: Int) {
        let ls = readLines()
        let ctx = settings.shareContext
        return (ls.suffix(n).reversed().map { CorrectionEvents.outgoing($0, context: ctx) }, ls.count)
    }

    func clearQueue() { q.async { self.writeLines([]) } }

    var status: String { lastResult }

    // MARK: schedule

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 60, repeating: Self.period)
        t.setEventHandler { [weak self] in self?.run() }
        t.resume()
        timer = t
    }

    /// one more run after a delay (Retry-After, a delete that has to go through)
    private func runLater(_ secs: Double) {
        q.asyncAfter(deadline: .now() + min(24 * 3600, max(30, secs))) { [weak self] in self?.run() }
    }

    // MARK: network (upload queue only)

    private func request(_ method: String, _ url: String, body: Data?) -> (code: Int, retryAfter: Double?, body: String) {
        guard let u = URL(string: url) else { return (-1, nil, "bad url") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let b = body {
            req.httpBody = b
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        var out: (Int, Double?, String) = (-1, nil, "")
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let h = resp as? HTTPURLResponse {
                let ra = (h.value(forHTTPHeaderField: "Retry-After")).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                out = (h.statusCode, ra, data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(300)) } ?? "")
            } else {
                out = (-1, nil, err.map { "\($0.localizedDescription)" } ?? "no response")
            }
            sem.signal()
        }
        task.resume()
        sem.wait()
        return out
    }

    private func run() {
        for id in settings.pendingDeletes {
            let r = request("DELETE", UploadCore.deleteURL(Settings.uploadURL, installId: id), body: nil)
            switch UploadCore.classify(r.code) {
            case .retry:
                lastResult = "delete pending (\(r.code))"
                runLater(r.retryAfter ?? 900)
                return
            default:
                // 200 = gone; a 4xx will never succeed: drop it rather than block uploads forever
                settings.pendingDeletes = settings.pendingDeletes.filter { $0 != id }
            }
        }
        guard settings.shareData else { return }
        let lines = readLines()
        guard !lines.isEmpty else { return }
        let install = settings.installId, version = Updater.currentVersion
        let d = UploadCore.drain(lines) { chunk in
            guard let body = UploadCore.envelope(installId: install, appVersion: version, lines: chunk,
                                                 context: self.settings.shareContext) else { return (400, nil) }
            let r = self.request("POST", Settings.uploadURL, body: body)
            if UploadCore.classify(r.code) == .skip { self.log.notice("upload rejected \(r.code): \(r.body, privacy: .public)") }
            return (r.code, r.retryAfter)
        }
        // lines queued while this ran were appended after these; only the consumed front goes
        if d.consumed > 0 { writeLines(Array(readLines().dropFirst(d.consumed))) }
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        lastResult = "\(t): sent \(d.sent), skipped \(d.skipped)" + (d.retryCode.map { ", stopped (\($0)), retrying later" } ?? "")
        if d.retryCode != nil { runLater(d.retryAfter ?? 900) }
    }

    /// "Delete my uploaded data": queue the current id for deletion, switch to a new one, clear the queue, try now.
    /// done(true) = the server confirmed; false = it stays pending and is retried before any upload.
    func deleteMyData(done: @escaping (Bool) -> Void) {
        q.async {
            let old = self.settings.installId
            self.settings.pendingDeletes = self.settings.pendingDeletes + [old]
            self.settings.rotateInstallId()
            self.writeLines([])
            let r = self.request("DELETE", UploadCore.deleteURL(Settings.uploadURL, installId: old), body: nil)
            let ok = UploadCore.classify(r.code) == .advance
            if ok { self.settings.pendingDeletes = self.settings.pendingDeletes.filter { $0 != old } } else { self.runLater(r.retryAfter ?? 60) }
            self.lastResult = ok ? "uploaded data deleted" : "delete pending (\(r.code)), retried automatically"
            DispatchQueue.main.async { done(ok) }
        }
    }
}
