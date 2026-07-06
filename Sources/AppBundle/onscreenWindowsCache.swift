import CoreGraphics
import Foundation

// Fork(dwindle): set of CGWindowIDs that macOS currently reports as on-screen
// (`kCGWindowIsOnscreen == true`). Used to detect background native macOS tabs: a window that
// lives in the tiling tree but is NOT on-screen (and isn't minimized/fullscreen/hidden) is a
// background tab that must be excluded from the layout. MacWindow.windowId IS the CGWindowID
// (see windowLevelCache.swift), so no extra mapping is needed.
//
// Unlike windowLevelCache, this must be recomputed every refresh tick — on-screen state flips on
// every tab switch — so there is intentionally no caching here.
@MainActor
func getOnscreenWindowIds() -> Set<UInt32> {
    var result: Set<UInt32> = []
    // No .optionOnScreenOnly: we need offscreen windows in the list too, to read their flag.
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return result }
    for elem in cfArray {
        let dict = elem as NSDictionary
        guard (dict[kCGWindowIsOnscreen] as? NSNumber)?.boolValue == true else { continue }
        guard let rawId = dict[kCGWindowNumber] else { continue }
        result.insert(((rawId as! CFNumber) as NSNumber).uint32Value)
    }
    return result
}
