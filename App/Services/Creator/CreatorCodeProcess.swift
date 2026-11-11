import Darwin
import Foundation
import WebKit

/// WebKit SPI is isolated here. Missing selectors or shared ownership fail closed.
/// Never searches for, signals, or terminates another application's WebKit processes.
@MainActor enum CreatorCodeProcess {
    private static let pidSelector = NSSelectorFromString("_webProcessIdentifier")
    private static let terminateSelector = NSSelectorFromString("_killWebContentProcessAndResetState")
    private final class Owner { weak var view: WKWebView?; init(_ view: WKWebView) { self.view = view } }
    private static var owners: [ObjectIdentifier: Owner] = [:]
    private static var claimed = Set<ObjectIdentifier>()
    static func observe(_ view: WKWebView) { owners[ObjectIdentifier(view)] = Owner(view) }
    static var supported: Bool { WKWebView.instancesRespond(to: pidSelector) && WKWebView.instancesRespond(to: terminateSelector) }
    static func identifier(_ view: WKWebView) -> pid_t? {
        guard supported, view.responds(to: pidSelector) else { return nil }
        typealias Read = @convention(c) (AnyObject, Selector) -> pid_t
        let pid = unsafeBitCast(view.method(for: pidSelector), to: Read.self)(view, pidSelector)
        return pid > 0 ? pid : nil
    }
    static func claim(_ view: WKWebView) throws -> pid_t {
        owners = owners.filter { $0.value.view != nil }
        claimed.formIntersection(owners.keys)
        guard !view.configuration.websiteDataStore.isPersistent, let pid = identifier(view),
              !owners.values.contains(where: { owner in
                  guard let other = owner.view, other !== view else { return false }
                  return identifier(other) == pid || other.configuration.websiteDataStore === view.configuration.websiteDataStore
              })
        else { throw CreatorRuntimeFailure.pageFailed }
        owners[ObjectIdentifier(view)] = Owner(view)
        claimed.insert(ObjectIdentifier(view))
        return pid
    }
    @discardableResult static func terminate(_ view: WKWebView, owned pid: pid_t) -> Bool {
        guard claimed.contains(ObjectIdentifier(view)), owners[ObjectIdentifier(view)]?.view === view, identifier(view) == pid,
              !owners.values.contains(where: { $0.view !== view && $0.view.flatMap(identifier) == pid })
        else { return false }
        typealias Terminate = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(view.method(for: terminateSelector), to: Terminate.self)(view, terminateSelector)
        claimed.remove(ObjectIdentifier(view))
        return true
    }
    static func usage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { value in
            value.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info : nil
    }
}
