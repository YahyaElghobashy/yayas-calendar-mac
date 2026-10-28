#if !YC_DATA_TESTS
import Foundation
import WidgetKit

/// The app's `TimelineReloader`. Excluded from the headless data tests (`-D YC_DATA_TESTS`), which
/// record reloads instead. On the main thread (a widget tap) the reload is asked on the spot, so it
/// reaches WidgetKit while the agent is still active (free, unthrottled) and before the router hands
/// the front back; from background threads (sync passes) it hops to main as before.
final class WidgetKitReloader: TimelineReloader, @unchecked Sendable {
    func reloadTimelines(ofKind kind: String) {
        if Thread.isMainThread {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        } else {
            DispatchQueue.main.async { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        }
    }
}
#endif
