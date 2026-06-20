import Foundation
import CoreGraphics

/// Thin, defensive wrapper around the private CoreGraphics window-space (CGS)
/// API used to make another app's window appear on every Mission Control space.
///
/// We use `CGSCopyManagedDisplaySpaces` to enumerate all spaces and
/// `CGSAddWindowsToSpaces` to put a window on every one — the approach window
/// managers (yabai etc.) rely on, which is far more reliable than the older
/// sticky-tag bit. All symbols are resolved at runtime via `dlsym`, so if a
/// future macOS removes them the calls simply no-op and pinning degrades to
/// scrcpy's `--always-on-top`.
enum PrivateSpaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias AddRemoveWindowsFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?

    // Immutable after init and only ever read, so the unchecked annotation is
    // sound; the raw pointer type just isn't Sendable.
    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_NOW)

    private static let mainConnection: MainConnectionFn? =
        sym("CGSMainConnectionID")
    private static let addWindowsToSpaces: AddRemoveWindowsFn? =
        sym("CGSAddWindowsToSpaces")
    private static let removeWindowsFromSpaces: AddRemoveWindowsFn? =
        sym("CGSRemoveWindowsFromSpaces")
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? =
        sym("CGSCopyManagedDisplaySpaces")

    private static func sym<T>(_ name: String) -> T? {
        guard let s = dlsym(handle, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    /// Add or remove a window from **every** space so it shows on all desktops.
    static func setWindowOnAllSpaces(_ windowID: CGWindowID, enabled: Bool) {
        guard let mainConnection,
              let copySpaces = copyManagedDisplaySpaces else { return }
        let cid = mainConnection()
        let spaceIDs = allSpaceIDs(cid: cid, copySpaces: copySpaces)
        guard !spaceIDs.isEmpty else { return }

        let windows = [NSNumber(value: windowID)] as CFArray
        let spaces = spaceIDs.map { NSNumber(value: $0) } as CFArray
        if enabled {
            addWindowsToSpaces?(cid, windows, spaces)
        } else {
            removeWindowsFromSpaces?(cid, windows, spaces)
        }
    }

    /// Collect every space ID across all displays from the CGS managed-spaces
    /// description (an array of display dicts, each with a "Spaces" array of
    /// dicts carrying a numeric "id64").
    private static func allSpaceIDs(cid: Int32,
                                    copySpaces: CopyManagedDisplaySpacesFn) -> [UInt64] {
        guard let displays = copySpaces(cid) as? [[String: Any]] else { return [] }
        var ids: [UInt64] = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                // Skip fullscreen/tiled spaces (type 4) — only normal user spaces.
                if let type = space["type"] as? Int, type == 4 { continue }
                if let id = space["id64"] as? UInt64 {
                    ids.append(id)
                } else if let id = space["id64"] as? NSNumber {
                    ids.append(id.uint64Value)
                } else if let id = space["ManagedSpaceID"] as? NSNumber {
                    ids.append(id.uint64Value)
                }
            }
        }
        return ids
    }
}
