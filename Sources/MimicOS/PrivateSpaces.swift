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
    /// Returns true if the call path was available and ran.
    @discardableResult
    static func setWindowOnAllSpaces(_ windowID: CGWindowID, enabled: Bool) -> Bool {
        guard let mainConnection,
              let copySpaces = copyManagedDisplaySpaces,
              windowID != 0 else { return false }
        let cid = mainConnection()
        let spaceIDs = allSpaceIDs(cid: cid, copySpaces: copySpaces)
        guard !spaceIDs.isEmpty else { return false }

        let windows = [NSNumber(value: windowID)] as CFArray
        let spaces = spaceIDs.map { NSNumber(value: $0) } as CFArray
        if enabled {
            guard let addWindowsToSpaces else { return false }
            addWindowsToSpaces(cid, windows, spaces)
        } else {
            guard let removeWindowsFromSpaces else { return false }
            removeWindowsFromSpaces(cid, windows, spaces)
        }
        return true
    }

    /// Find scrcpy's mirror window via the public CGWindowList (no Accessibility
    /// permission required), matched by owner name and window title. Returns its
    /// CGWindowID and on-screen bounds. This is the reliable path for pinning,
    /// which only needs the window number — not AX.
    static func findScrcpyWindow(titleContains title: String) -> (id: CGWindowID, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Prefer an exact title/owner match; fall back to any window owned by scrcpy.
        var fallback: (CGWindowID, CGRect)?
        for info in list {
            let owner = (info[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            guard owner.contains("scrcpy") else { continue }
            guard let num = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let bounds = boundsRect(info[kCGWindowBounds as String]) ?? .zero
            let name = info[kCGWindowName as String] as? String ?? ""
            if name == title || name.contains(title) {
                return (num, bounds)
            }
            if fallback == nil, bounds.width > 100 {
                fallback = (num, bounds)
            }
        }
        if let fb = fallback { return (fb.0, fb.1) }
        return nil
    }

    private static func boundsRect(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: CGFloat],
              let x = dict["X"], let y = dict["Y"],
              let w = dict["Width"], let h = dict["Height"] else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
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
