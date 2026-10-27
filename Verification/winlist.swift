import CoreGraphics
import Foundation

/// Tiny CGWindowList helper used by the QA scripts to discover window ids for
/// `screencapture -l <id>`. No Accessibility permission is required.
///
/// Usage:
///   winlist                # list on-screen windows owned by OpenStitch
///   winlist --all          # list every on-screen window
///   winlist <owner-substring>
///
/// Output: one line per window:
///   id=<n> layer=<n> pid=<n> owner=<name> name=<title> bounds=<x,y,w,h>

let args = Array(CommandLine.arguments.dropFirst())
let showAll = args.contains("--all")
let filter = args.first(where: { !$0.hasPrefix("--") })

guard let rawList = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("winlist: CGWindowListCopyWindowInfo failed\n".utf8))
    exit(2)
}

var count = 0
for info in rawList {
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    if !showAll {
        guard let filter, owner.localizedCaseInsensitiveContains(filter) else { continue }
    }
    let id = info[kCGWindowNumber as String] as? Int ?? -1
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    let pid = info[kCGWindowOwnerPID as String] as? Int ?? -1
    let name = info[kCGWindowName as String] as? String ?? ""
    let boundsDict = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = boundsDict["X"] as? Double ?? -1
    let y = boundsDict["Y"] as? Double ?? -1
    let w = boundsDict["Width"] as? Double ?? -1
    let h = boundsDict["Height"] as? Double ?? -1
    print("id=\(id) layer=\(layer) pid=\(pid) owner=\(owner) name=\(name) bounds=\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))")
    count += 1
}
print("count=\(count)")
