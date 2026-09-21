import Foundation

public struct DisplayIdentity: Equatable, Sendable {
    public let displayID: Int
    public let uuid: String?
    public let isBuiltin: Bool

    public init(displayID: Int, uuid: String?, isBuiltin: Bool = false) {
        self.displayID = displayID
        self.uuid = uuid
        self.isBuiltin = isBuiltin
    }
}

public enum BrightnessRestoration {
    /// User default: every released display returns to full brightness.
    public static let defaultBrightness = 1.0

    public static func target(for saved: DisplayBrightness, active: [DisplayIdentity]) throws -> Int {
        let matches = active.filter {
            if let uuid = saved.uuid { return $0.uuid == uuid }
            return $0.displayID == saved.displayID
        }
        guard matches.count == 1 else {
            throw BetterDisplayError.commandFailed("saved display \(saved.uuid ?? String(saved.displayID)) is unavailable; brightness backup retained")
        }
        return matches[0].displayID
    }

    public static func restore(_ backup: BrightnessBackup, client: BetterDisplayClient) throws {
        let active = try client.displays()
        var failures: [String] = []
        // A missing display must not prevent the remaining screens from recovering.
        for saved in backup.displays {
            do {
                let id = try target(for: saved, active: active)
                let value = try client.setBrightnessAndReadback(displayID: id, value: defaultBrightness)
                guard abs(value - defaultBrightness) <= 0.01 else {
                    throw BetterDisplayError.commandFailed("displayID=\(id) brightness \(value), expected \(defaultBrightness)")
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            throw BetterDisplayError.commandFailed(failures.joined(separator: "; "))
        }
    }

    public static func reconciliationPlan(
        existing: [DisplayBrightness],
        active: [DisplayIdentity],
        currentBrightness: (Int) throws -> Double
    ) throws -> (updated: [DisplayBrightness], toDim: [DisplayBrightness]) {
        var updated = existing
        var toDim: [DisplayBrightness] = []
        for identity in active {
            let index = existing.firstIndex { saved in
                if let uuid = saved.uuid { return uuid == identity.uuid }
                return saved.displayID == identity.displayID
            }
            if let index {
                let saved = existing[index]
                if saved.displayID == identity.displayID {
                    if try currentBrightness(identity.displayID) > 0.01 { toDim.append(saved) }
                } else {
                    let moved = DisplayBrightness(
                        displayID: identity.displayID,
                        brightness: saved.brightness,
                        uuid: saved.uuid
                    )
                    updated[index] = moved
                    toDim.append(moved)
                }
            } else {
                let added = DisplayBrightness(
                    displayID: identity.displayID,
                    brightness: try currentBrightness(identity.displayID),
                    uuid: identity.uuid
                )
                updated.append(added)
                toDim.append(added)
            }
        }
        return (updated, toDim)
    }
}
