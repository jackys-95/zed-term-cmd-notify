import Foundation

final class BindingRegistry<Source: AnyObject> {
    private var sources: [String: Source] = [:]
    private let lock = NSLock()

    @discardableResult
    func insert(_ source: Source, for bindingID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard sources[bindingID] == nil else {
            return false
        }
        sources[bindingID] = source
        return true
    }

    func source(for bindingID: String) -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return sources[bindingID]
    }
}
