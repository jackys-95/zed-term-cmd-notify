@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin

// The probe's only private API. Resolve it at runtime so a missing symbol
// leaves the existing public geometry path available.
@MainActor
enum PrivateWindowID {
    private typealias Function = @convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> Int32

    // Keep the framework handle open for the lifetime of the function pointer.
    private static let framework = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        RTLD_LAZY | RTLD_LOCAL
    )
    private static let function: Function? = {
        guard let framework,
              let symbol = dlsym(framework, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static var available: Bool { function != nil }

    static func lookup(_ element: AXUIElement) throws -> CGWindowID {
        guard let function else {
            throw WindowLookupError.unavailable("Private window-ID conversion is unavailable")
        }
        var id: CGWindowID = 0
        let error = function(element, &id)
        guard error == 0, id != 0 else {
            throw WindowLookupError.unavailable(
                "Private window-ID conversion failed: AXError \(error), window ID \(id)"
            )
        }
        return id
    }

    static func inspect(_ element: AXUIElement) -> [String: Any] {
        guard available else { return ["available": false] }
        do {
            return ["available": true, "windowID": try lookup(element)]
        } catch {
            return ["available": true, "error": String(describing: error)]
        }
    }
}
