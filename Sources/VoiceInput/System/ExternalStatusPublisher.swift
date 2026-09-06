import Foundation

/// A text-free status bridge for local menu bars and other external controls.
/// Notifications are hints; the atomically written snapshot is the source of truth.
final class ExternalStatusPublisher: @unchecked Sendable {
    static let notificationName = Notification.Name("com.zhijie.VoiceInput.stateChanged")
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/VoiceInput/status.json")
    }

    struct Snapshot: Codable, Equatable {
        let version: Int
        let pid: Int32
        let state: String

        init(phase: DictationPhase, enabled: Bool, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
            version = 1
            self.pid = pid
            if !enabled { state = "disabled"; return }
            switch phase {
            case .idle: state = "idle"
            case .connecting: state = "connecting"
            case .listening: state = "recording"
            case .finalizing, .refining, .injecting: state = "processing"
            case .reviewing: state = "reviewing"
            case .error: state = "error"
            }
        }

        init(offlinePID: Int32) {
            version = 1
            pid = offlinePID
            state = "offline"
        }
    }

    private let queue = DispatchQueue(label: "com.zhijie.VoiceInput.external-status")
    private let url: URL
    private let notify: () -> Void
    private var last: Snapshot?
    private var stopped = false

    init(url: URL = ExternalStatusPublisher.defaultURL,
         notify: @escaping () -> Void = {
             DistributedNotificationCenter.default().postNotificationName(
                 ExternalStatusPublisher.notificationName, object: nil, userInfo: nil, deliverImmediately: true)
         }) {
        self.url = url
        self.notify = notify
    }

    func publish(phase: DictationPhase, enabled: Bool) {
        let snapshot = Snapshot(phase: phase, enabled: enabled)
        queue.async { [self] in
            guard !stopped else { return }
            write(snapshot)
        }
    }

    func finish() {
        queue.sync {
            stopped = true
            write(Snapshot(offlinePID: ProcessInfo.processInfo.processIdentifier))
        }
    }

    func waitForPendingWrites() { queue.sync {} }

    private func write(_ snapshot: Snapshot) {
        guard snapshot != last else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            last = snapshot
            notify()
        } catch {
            // Optional integration must never interrupt recording or text delivery.
        }
    }
}
