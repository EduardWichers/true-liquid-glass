import AppKit
import ApplicationServices
import Darwin

/// Small, type-checked wrappers around the Accessibility C API.
/// Every getter returns nil on any error or unexpected type instead of crashing.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        if CFGetTypeID(value) == CFNumberGetTypeID() { return (value as! NSNumber).boolValue }
        return nil
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! [AnyObject]
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    static func url(_ element: AXUIElement, _ name: String = kAXURLAttribute) -> URL? {
        guard let value = attribute(element, name) else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL) as URL }
        if CFGetTypeID(value) == CFStringGetTypeID() { return URL(string: (value as! CFString) as String) }
        return nil
    }

    static func point(_ element: AXUIElement, _ name: String = kAXPositionAttribute) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point), point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ name: String = kAXSizeAttribute) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size), size.width.isFinite, size.height.isFinite else { return nil }
        return size
    }

    /// Frame in Quartz (top-left origin) global coordinates.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element), let size = size(element), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// The window that contains `element` (the element itself if it is a window).
    static func window(containing element: AXUIElement) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == kAXWindowRole { return element }
        if let window = self.element(element, kAXWindowAttribute) { return window }
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let node = current, let parent = self.element(node, kAXParentAttribute) else { return nil }
            if string(parent, kAXRoleAttribute) == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    @discardableResult
    static func setMinimized(_ element: AXUIElement, _ minimized: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                     (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> AXError {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
    }

    @discardableResult
    static func setTimeout(_ element: AXUIElement, seconds: Float) -> AXError {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow` is not public API, so it is looked up dynamically and
    /// every caller has a fallback (matching on pid + frame) for when it is missing.
    private static let getWindowFunction: GetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            logWarning("_AXUIElementGetWindow unavailable; window ID is matched by position")
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        guard let function = getWindowFunction else { return nil }
        var id: CGWindowID = 0
        guard function(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement (window no longer exists)"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete (app not responding)"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled (no Accessibility permission)"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "AXError \(error.rawValue)"
        }
    }
}
