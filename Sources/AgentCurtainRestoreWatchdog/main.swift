import AgentCurtainCore
import Darwin
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 4, let ownerPID = Int32(arguments[1]) else {
    fail("usage: AgentCurtainRestoreWatchdog <owner-pid> <backup-path> <betterdisplaycli>", code: 2)
}

let backupURL = URL(fileURLWithPath: arguments[2])
let client: BetterDisplayClient
do {
    client = try BetterDisplayClient(executable: URL(fileURLWithPath: arguments[3]))
} catch {
    fail(error.localizedDescription)
}

while kill(ownerPID, 0) == 0 {
    usleep(250_000)
}

guard FileManager.default.fileExists(atPath: backupURL.path) else { exit(0) }

do {
    guard let claimed = try BrightnessBackupStore.claim(backupURL) else { exit(0) }
    do {
        let backup = try BrightnessBackupStore.read(from: claimed)
        for display in backup.displays {
            try client.setBrightness(displayID: display.displayID, value: display.brightness)
        }
        try FileManager.default.removeItem(at: claimed)
        exit(0)
    } catch {
        try? BrightnessBackupStore.relinquish(claimed, to: backupURL)
        throw error
    }
} catch {
    fail("brightness restore failed: \(error.localizedDescription)")
}
