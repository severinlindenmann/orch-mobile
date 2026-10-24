import Foundation

enum PushGroup {
    static let identifier = "group.io.severin.orch"
    /// `<group.io.severin.orch>/push`: the directory the hub push intake (`HubStorage`) and the notification extension share; nil without the entitlement.
    static func pushDir() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?.appendingPathComponent("push", isDirectory: true)
    }
}
