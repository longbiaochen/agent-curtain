import AgentCurtainCore
import Foundation

final class CurtainCoordinator {
    enum Phase: String {
        case starting
        case open
        case drawing
        case drawn
        case opening
    }

    private let paths: CurtainPaths
    private let blocker = InputBlocker()
    private let banners = BannerController()
    private let brightness: BrightnessController
    private let worker = DispatchQueue(label: "com.longbiaochen.AgentCurtain.operations")
    private var configuration = CurtainConfiguration(allowedRules: [], deniedRules: [])
    private var autoOpenTimer: Timer?
    private var pendingOpenCompletions: [(ControlResponse) -> Void] = []

    private(set) var phase: Phase = .starting
    private(set) var since: Date?
    private(set) var displayCount = 0
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    init(paths: CurtainPaths) {
        self.paths = paths
        brightness = BrightnessController(paths: paths)
        blocker.onReleaseHotkey = { [weak self] in self?.open(completion: { _ in }) }
        banners.onScreensChanged = { [weak self] in self?.screensChanged() }
    }

    func prepare(completion: @escaping () -> Void) {
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let config = try CurtainConfiguration.load(from: self.paths)
                try self.brightness.recoverStaleBackup()
                DispatchQueue.main.async {
                    self.configuration = config
                    self.phase = .open
                    self.lastError = nil
                    self.changed()
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .open
                    self.lastError = "startup recovery failed: \(error.localizedDescription)"
                    self.changed()
                    completion()
                }
            }
        }
    }

    func handle(_ command: ControlCommand, completion: @escaping (ControlResponse) -> Void) {
        switch command {
        case .draw(let duration, let allowAnyInjected):
            draw(duration: duration, allowAnyInjected: allowAnyInjected, completion: completion)
        case .open:
            open(completion: completion)
        case .status:
            completion(response(ok: true))
        case .reload:
            reload(completion: completion)
        case .quit:
            completion(ControlResponse(ok: false, state: phase.rawValue, error: "quit must be handled by the app delegate"))
        }
    }

    func draw(
        duration: TimeInterval? = nil,
        allowAnyInjected: Bool = false,
        completion: @escaping (ControlResponse) -> Void
    ) {
        precondition(Thread.isMainThread)
        if phase == .drawn {
            completion(response(ok: true))
            return
        }
        guard phase == .open else {
            completion(ControlResponse(ok: false, state: phase.rawValue, error: "curtain transition already in progress"))
            return
        }
        guard InputBlocker.isAccessibilityTrusted(prompt: true) else {
            lastError = "Accessibility permission is required for AgentCurtain"
            changed()
            completion(ControlResponse(ok: false, state: "open", error: lastError))
            return
        }
        if allowAnyInjected && configuration.deniedRules.isEmpty {
            completion(ControlResponse(ok: false, state: "open", error: "--allow-any-injected requires a non-empty denylist"))
            return
        }

        phase = .drawing
        lastError = nil
        changed()
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let count = try self.brightness.dimAllDisplays()
                DispatchQueue.main.async {
                    guard self.phase == .drawing else {
                        completion(ControlResponse(ok: false, state: self.phase.rawValue, error: "draw was cancelled"))
                        return
                    }
                    do {
                        try self.blocker.start(
                            configuration: self.configuration,
                            allowAnyInjected: allowAnyInjected
                        )
                        self.banners.show()
                        self.displayCount = count
                        self.since = Date()
                        self.phase = .drawn
                        self.scheduleAutomaticOpen(after: duration)
                        self.changed()
                        completion(self.response(ok: true))
                    } catch {
                        self.phase = .opening
                        self.lastError = error.localizedDescription
                        self.changed()
                        self.worker.async {
                            let restoreError = Result { try self.brightness.restoreAllDisplays() }.failure
                            DispatchQueue.main.async {
                                self.phase = .open
                                self.displayCount = 0
                                self.changed()
                                let message = [error.localizedDescription, restoreError?.localizedDescription]
                                    .compactMap { $0 }.joined(separator: "; ")
                                completion(ControlResponse(ok: false, state: "open", error: message))
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if self.phase == .drawing { self.phase = .open }
                    self.lastError = error.localizedDescription
                    self.changed()
                    completion(ControlResponse(ok: false, state: self.phase.rawValue, error: error.localizedDescription))
                }
            }
        }
    }

    func open(completion: @escaping (ControlResponse) -> Void) {
        precondition(Thread.isMainThread)
        if phase == .open {
            completion(response(ok: true))
            return
        }
        if phase == .starting {
            completion(ControlResponse(ok: false, state: phase.rawValue, error: "AgentCurtain is still starting"))
            return
        }
        pendingOpenCompletions.append(completion)
        if phase == .opening { return }

        phase = .opening
        autoOpenTimer?.invalidate()
        autoOpenTimer = nil
        blocker.stop()
        banners.hide()
        changed()
        worker.async { [weak self] in
            guard let self else { return }
            let restoreError = Result { try self.brightness.restoreAllDisplays() }.failure
            DispatchQueue.main.async {
                self.phase = .open
                self.since = nil
                self.displayCount = 0
                self.lastError = restoreError?.localizedDescription
                self.changed()
                let response = self.response(ok: restoreError == nil)
                let callbacks = self.pendingOpenCompletions
                self.pendingOpenCompletions.removeAll()
                callbacks.forEach { $0(response) }
            }
        }
    }

    func reload(completion: @escaping (ControlResponse) -> Void) {
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let config = try CurtainConfiguration.load(from: self.paths)
                DispatchQueue.main.async {
                    self.configuration = config
                    if self.phase == .drawn { self.blocker.update(configuration: config) }
                    self.changed()
                    completion(self.response(ok: true))
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.changed()
                    completion(ControlResponse(ok: false, state: self.phase.rawValue, error: error.localizedDescription))
                }
            }
        }
    }

    func response(ok: Bool) -> ControlResponse {
        let counters = blocker.counters()
        let stableState = phase == .drawn ? "drawn" : (phase == .open ? "open" : phase.rawValue)
        return ControlResponse(
            ok: ok,
            state: stableState,
            displays: displayCount,
            blocked: counters.blocked,
            allowed: counters.allowed,
            denied: counters.deniedPIDs,
            since: since.map { ISO8601DateFormatter().string(from: $0) },
            error: ok ? nil : lastError
        )
    }

    var statusSummary: String {
        let counters = blocker.counters()
        switch phase {
        case .drawn:
            return "幕帘已拉上 · 阻断 \(counters.blocked) · 放行 \(counters.allowed)"
        case .open:
            return lastError.map { "幕帘已拉开 · \($0)" } ?? "幕帘已拉开"
        case .starting: return "正在启动…"
        case .drawing: return "正在拉上幕帘…"
        case .opening: return "正在拉开幕帘…"
        }
    }

    private func scheduleAutomaticOpen(after duration: TimeInterval?) {
        autoOpenTimer?.invalidate()
        guard let duration else { return }
        autoOpenTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.open(completion: { _ in })
        }
    }

    private func screensChanged() {
        guard phase == .drawn else { return }
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let count = try self.brightness.dimNewDisplays()
                DispatchQueue.main.async {
                    guard self.phase == .drawn else { return }
                    self.displayCount = count
                    self.changed()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "display reconciliation failed: \(error.localizedDescription)"
                    self.changed()
                }
            }
        }
    }

    private func changed() {
        onChange?()
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
