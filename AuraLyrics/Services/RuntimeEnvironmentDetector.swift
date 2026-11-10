import Foundation
import ActivityKit
import Combine
import ObjectiveC

/// Runtime environment detector, LCAppInfo auto-configurator, and XPC translation bridge.
@MainActor
public final class RuntimeEnvironmentDetector: ObservableObject {
    public static let shared = RuntimeEnvironmentDetector()

    @Published public private(set) var isLiveContainer: Bool = false
    @Published public private(set) var areLiveActivitiesAvailable: Bool = false
    @Published public private(set) var isUsingContinuedProcessingLiveActivity: Bool = false
    @Published public private(set) var environmentDescription: String = String(localized: "檢測中...")

    private init() {
        detectEnvironment()
    }

    public func detectEnvironment() {
        let env = ProcessInfo.processInfo.environment

        // 1. Inspect LiveContainer environment variables, bundle path, and classes.
        let hasLCHome = env["LC_HOME_PATH"] != nil
        let hasLCBundle = Bundle.main.bundlePath.contains("LiveContainer")
        let hasLCClass = NSClassFromString("LCSharedUtils") != nil

        self.isLiveContainer = hasLCHome || hasLCBundle || hasLCClass

        // 2. Configure LiveContainer auto-repair and bridge if applicable.
        if isLiveContainer {
            ensureLCAppInfoConfigured()

            if #available(iOS 26.0, *) {
                // Ensure runtime bridge is active for first launch before container reboot.
                LCBackgroundTaskRuntimeBridge.shared.installBridgeIfNeeded()

                self.isUsingContinuedProcessingLiveActivity = true
                self.areLiveActivitiesAvailable = true
                self.environmentDescription = String(localized: "LiveContainer 容器環境（支援 iOS 26+ 系統免擴充動態島與即時動態）")
            } else {
                self.isUsingContinuedProcessingLiveActivity = false
                self.areLiveActivitiesAvailable = false
                self.environmentDescription = String(localized: "LiveContainer 容器環境（採用免 Extension 的子母畫面 PiP 懸浮膠囊）")
            }
        } else {
            self.isUsingContinuedProcessingLiveActivity = false
            if #available(iOS 16.2, *) {
                let authInfo = ActivityAuthorizationInfo()
                self.areLiveActivitiesAvailable = authInfo.areActivitiesEnabled
            } else {
                self.areLiveActivitiesAvailable = false
            }
            self.environmentDescription = String(localized: "獨立側載安裝環境（支援原生動態島 / 即時動態與子母畫面 PiP 雙引擎）")
        }
    }

    /// Automatically writes fixBackgroundTaskIdentifiers = true to LCAppInfo.plist if running in LiveContainer.
    private func ensureLCAppInfoConfigured() {
        let bundleURL = Bundle.main.bundleURL
        let lcAppInfoURL = bundleURL.appendingPathComponent("LCAppInfo.plist")

        var plistDict: [String: Any] = [:]
        if let data = try? Data(contentsOf: lcAppInfoURL),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = obj as? [String: Any] {
            plistDict = dict
        }

        if plistDict["fixBackgroundTaskIdentifiers"] as? Bool != true {
            plistDict["fixBackgroundTaskIdentifiers"] = true
            if let outputData = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) {
                try? outputData.write(to: lcAppInfoURL, options: .atomic)
            }
        }

        if let userDefaultsClass = NSClassFromString("NSUserDefaults") as AnyObject as? NSObjectProtocol {
            let sel = NSSelectorFromString("guestAppInfo")
            if userDefaultsClass.responds(to: sel),
               let unmanaged = (userDefaultsClass as AnyObject).perform(sel),
               let infoDict = unmanaged.takeUnretainedValue() as? NSMutableDictionary {
                infoDict["fixBackgroundTaskIdentifiers"] = true
            }
        }
    }

    /// Returns recommended display engine mode based on runtime detection.
    public var recommendedEngine: DisplayEngineMode {
        if isLiveContainer {
            if isUsingContinuedProcessingLiveActivity {
                return .both
            } else {
                return .pipCapsule
            }
        } else {
            return .both
        }
    }
}

// MARK: - LiveContainer Background Task Runtime Bridge

fileprivate typealias EncodeActivityIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
fileprivate typealias DecodeActivityIMP = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
fileprivate typealias CancelTaskIMP = @convention(c) (AnyObject, Selector, NSString) -> Void
fileprivate typealias PermissibleIMP = @convention(c) (AnyObject, Selector, NSString) -> ObjCBool

private func bridgeHookEncodeActivity(activity: AnyObject, selector: Selector, coder: AnyObject) {
    LCBackgroundTaskRuntimeBridge.handleEncodeActivity(activity: activity, selector: selector, coder: coder)
}

private func bridgeHookDecodeActivity(activity: AnyObject, selector: Selector, coder: AnyObject) -> AnyObject {
    LCBackgroundTaskRuntimeBridge.handleDecodeActivity(activity: activity, selector: selector, coder: coder)
}

private func bridgeHookCancelTask(scheduler: AnyObject, selector: Selector, identifier: NSString) {
    LCBackgroundTaskRuntimeBridge.handleCancelTask(scheduler: scheduler, selector: selector, identifier: identifier)
}

private func bridgeHookPermissible(registry: AnyObject, selector: Selector, identifier: NSString) -> ObjCBool {
    LCBackgroundTaskRuntimeBridge.handlePermissibleIdentifier(registry: registry, selector: selector, identifier: identifier)
}

/// Runtime swizzling bridge providing transparent XPC identifier translation for guest BGContinuedProcessingTasks.
public final class LCBackgroundTaskRuntimeBridge: @unchecked Sendable {
    public static let shared = LCBackgroundTaskRuntimeBridge()

    private static var isBridgeInstalled = false
    private static let lock = NSRecursiveLock()

    private static var guestTaskPrefix: String = ""
    private static var hostTaskPrefix: String = ""
    private static var guestTaskIdentifiers: Set<String> = [
        "com.auralyrics.app.bgtask.lyrics",
        "com.auralyrics.app.bg.lyrics"
    ]
    private static var guestTaskFamilies: [String] = [
        "com.auralyrics.app.bgtask."
    ]

    private static let continuedProcessingReason = "com.apple.das.bgongoingprocessing"
    private static let continuedProcessingNamePrefix = "bgContinuedProcessing-"

    fileprivate static var originalEncodeActivity: EncodeActivityIMP?
    fileprivate static var originalDecodeActivity: DecodeActivityIMP?
    fileprivate static var originalCancelTask: CancelTaskIMP?
    fileprivate static var originalIsPermissibleIdentifier: PermissibleIMP?

    private init() {}

    /// Checks whether the bridge is already installed or hooks are already applied by TweakLoader.
    public func isBridgeInstalled() -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return checkBridgeInstalledUnlocked()
    }

    private func checkBridgeInstalledUnlocked() -> Bool {
        if Self.isBridgeInstalled { return true }

        dlopen("/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks", RTLD_LAZY)
        guard let registryClass = NSClassFromString("_BGTaskIdentifierRegistry") else { return false }

        let testIdentifier: NSString = "com.auralyrics.app.bgtask.lyrics"
        let sel = NSSelectorFromString("isPermissibleFullyComposedIdentifier:")

        if class_getClassMethod(registryClass, NSSelectorFromString("sharedRegistry")) != nil,
           let sharedRegistry = (registryClass as AnyObject).perform(NSSelectorFromString("sharedRegistry"))?.takeUnretainedValue() {
            if let method = class_getInstanceMethod(registryClass, sel) {
                let imp = method_getImplementation(method)
                let callable = unsafeBitCast(imp, to: PermissibleIMP.self)
                if callable(sharedRegistry, sel, testIdentifier).boolValue {
                    Self.isBridgeInstalled = true
                    return true
                }
            }
        }
        return false
    }

    /// Safely verifies whether BGTaskScheduler will accept the given identifier without throwing NSInternalInconsistencyException.
    @MainActor
    public func canRegisterTask(withIdentifier identifier: String) -> Bool {
        if !RuntimeEnvironmentDetector.shared.isLiveContainer {
            if let declarations = Bundle.main.infoDictionary?["BGTaskSchedulerPermittedIdentifiers"] as? [String] {
                if declarations.contains(identifier) { return true }
                for decl in declarations where decl.hasSuffix(".*") {
                    let prefix = String(decl.dropLast())
                    if identifier.hasPrefix(prefix) { return true }
                }
            }
            return false
        }

        Self.lock.lock()
        defer { Self.lock.unlock() }

        dlopen("/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks", RTLD_LAZY)
        guard let registryClass = NSClassFromString("_BGTaskIdentifierRegistry") else {
            return false
        }

        let sel = NSSelectorFromString("isPermissibleFullyComposedIdentifier:")
        let sharedSel = NSSelectorFromString("sharedRegistry")

        if class_getClassMethod(registryClass, sharedSel) != nil,
           let sharedRegistry = (registryClass as AnyObject).perform(sharedSel)?.takeUnretainedValue() {
            if let method = class_getInstanceMethod(registryClass, sel) {
                let imp = method_getImplementation(method)
                let callable = unsafeBitCast(imp, to: PermissibleIMP.self)
                return callable(sharedRegistry, sel, identifier as NSString).boolValue
            }
        }

        return Self.isGuestTaskIdentifier(identifier)
    }

    /// Installs the ObjC Runtime swizzling bridge if not already present.
    public func installBridgeIfNeeded() {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard !Self.isBridgeInstalled && !checkBridgeInstalledUnlocked() else { return }

        // 1. Load BackgroundTasks framework dynamically.
        dlopen("/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks", RTLD_LAZY)

        // 2. Resolve guest and host bundle identifiers.
        let guestBundleID = Bundle.main.bundleIdentifier ?? "com.auralyrics.app"
        let hostBundleID = Self.resolveHostBundleIdentifier()

        guard !guestBundleID.isEmpty, !hostBundleID.isEmpty, guestBundleID != hostBundleID else {
            return
        }

        Self.guestTaskPrefix = guestBundleID + "."
        Self.hostTaskPrefix = hostBundleID + "."

        // 3. Collect permitted identifiers from Info.plist declarations with defaults.
        var identifiers: Set<String> = [
            "\(guestBundleID).bgtask.lyrics",
            "\(guestBundleID).bg.lyrics"
        ]
        var families: [String] = [
            "\(guestBundleID).bgtask."
        ]
        if let declarations = Bundle.main.infoDictionary?["BGTaskSchedulerPermittedIdentifiers"] as? [String] {
            for id in declarations {
                guard id.hasPrefix(Self.guestTaskPrefix), id.count > 0, id.count <= 128 else { continue }
                if id.hasSuffix(".*") && id.components(separatedBy: "*").count == 2 {
                    families.append(String(id.dropLast()))
                } else if !id.contains("*") {
                    identifiers.insert(id)
                }
            }
        }

        Self.guestTaskIdentifiers = identifiers
        Self.guestTaskFamilies = families

        guard !identifiers.isEmpty || !families.isEmpty else { return }

        // 4. Resolve private classes and methods.
        guard let activityClass = NSClassFromString("_DASActivity"),
              let schedulerClass = NSClassFromString("_DASScheduler"),
              let registryClass = NSClassFromString("_BGTaskIdentifierRegistry")
        else {
            return
        }

        let encodeSel = NSSelectorFromString("encodeWithCoder:")
        let decodeSel = NSSelectorFromString("initWithCoder:")
        let cancelSel = NSSelectorFromString("cancelTaskRequestWithIdentifier:")
        let permissibleSel = NSSelectorFromString("isPermissibleFullyComposedIdentifier:")

        guard let encodeMethod = class_getInstanceMethod(activityClass, encodeSel),
              let decodeMethod = class_getInstanceMethod(activityClass, decodeSel),
              let cancelMethod = class_getInstanceMethod(schedulerClass, cancelSel),
              let permissibleMethod = class_getInstanceMethod(registryClass, permissibleSel)
        else {
            return
        }

        // 5. Swizzle _DASActivity encodeWithCoder:
        let hookEncodeIMP = unsafeBitCast(bridgeHookEncodeActivity as EncodeActivityIMP, to: IMP.self)
        let oldEncode = method_setImplementation(encodeMethod, hookEncodeIMP)
        LCBackgroundTaskRuntimeBridge.originalEncodeActivity = unsafeBitCast(oldEncode, to: EncodeActivityIMP.self)

        // 6. Swizzle _DASActivity initWithCoder:
        let hookDecodeIMP = unsafeBitCast(bridgeHookDecodeActivity as DecodeActivityIMP, to: IMP.self)
        let oldDecode = method_setImplementation(decodeMethod, hookDecodeIMP)
        LCBackgroundTaskRuntimeBridge.originalDecodeActivity = unsafeBitCast(oldDecode, to: DecodeActivityIMP.self)

        // 7. Swizzle _DASScheduler cancelTaskRequestWithIdentifier:
        let hookCancelIMP = unsafeBitCast(bridgeHookCancelTask as CancelTaskIMP, to: IMP.self)
        let oldCancel = method_setImplementation(cancelMethod, hookCancelIMP)
        LCBackgroundTaskRuntimeBridge.originalCancelTask = unsafeBitCast(oldCancel, to: CancelTaskIMP.self)

        // 8. Swizzle _BGTaskIdentifierRegistry isPermissibleFullyComposedIdentifier:
        let hookPermissibleIMP = unsafeBitCast(bridgeHookPermissible as PermissibleIMP, to: IMP.self)
        let oldPermissible = method_setImplementation(permissibleMethod, hookPermissibleIMP)
        LCBackgroundTaskRuntimeBridge.originalIsPermissibleIdentifier = unsafeBitCast(oldPermissible, to: PermissibleIMP.self)

        Self.isBridgeInstalled = true
    }

    private static func resolveHostBundleIdentifier() -> String {
        if let userDefaultsClass = NSClassFromString("NSUserDefaults") as AnyObject as? NSObjectProtocol {
            let sel = NSSelectorFromString("lcMainBundle")
            if userDefaultsClass.responds(to: sel),
               let unmanaged = (userDefaultsClass as AnyObject).perform(sel),
               let hostBundle = unmanaged.takeUnretainedValue() as? Bundle {
                let isLiveProcSel = NSSelectorFromString("isLiveProcess")
                var isLiveProc = false
                if let targetClass = NSClassFromString("NSUserDefaults"),
                   let method = class_getClassMethod(targetClass, isLiveProcSel) {
                    let imp = method_getImplementation(method)
                    typealias IsLiveProcessIMP = @convention(c) (AnyObject, Selector) -> Bool
                    let fn = unsafeBitCast(imp, to: IsLiveProcessIMP.self)
                    isLiveProc = fn(targetClass as AnyObject, isLiveProcSel)
                }
                if isLiveProc {
                    let rootPath = (hostBundle.bundlePath as NSString).deletingLastPathComponent
                    let grandRootPath = (rootPath as NSString).deletingLastPathComponent
                    if let rootBundle = Bundle(path: grandRootPath), let id = rootBundle.bundleIdentifier, !id.isEmpty {
                        return id
                    }
                }
                if let id = hostBundle.bundleIdentifier, !id.isEmpty {
                    return id
                }
            }
        }
        return "com.kdt.livecontainer"
    }

    private static func isGuestTaskIdentifier(_ identifier: String) -> Bool {
        guard identifier.count > 0, identifier.count <= 128, identifier.hasPrefix(guestTaskPrefix) else {
            return false
        }
        if guestTaskIdentifiers.contains(identifier) {
            return true
        }
        for family in guestTaskFamilies {
            if identifier.hasPrefix(family), identifier.count > family.count, !identifier.contains("*") {
                return true
            }
        }
        return false
    }

    private static func hostTaskIdentifier(_ identifier: String) -> String {
        guard isGuestTaskIdentifier(identifier) else { return identifier }
        let suffix = identifier.dropFirst(guestTaskPrefix.count)
        return hostTaskPrefix + suffix
    }

    private static func guestTaskIdentifier(_ identifier: String) -> String {
        guard identifier.hasPrefix(hostTaskPrefix) else { return identifier }
        let suffix = identifier.dropFirst(hostTaskPrefix.count)
        let candidate = guestTaskPrefix + suffix
        return isGuestTaskIdentifier(candidate) ? candidate : identifier
    }

    private static func isXPCCoder(_ coder: AnyObject, className: String) -> Bool {
        guard let cls = NSClassFromString(className) else { return false }
        return (coder as AnyObject).isKind(of: cls)
    }

    fileprivate static func handleEncodeActivity(activity: AnyObject, selector: Selector, coder: AnyObject) {
        guard let orig = originalEncodeActivity else { return }

        let launchReasonSel = NSSelectorFromString("launchReason")
        let clientProvidedIdSel = NSSelectorFromString("clientProvidedIdentifier")
        let nameSel = NSSelectorFromString("name")

        if isXPCCoder(coder, className: "NSXPCEncoder"),
           (activity as AnyObject).responds(to: launchReasonSel),
           (activity as AnyObject).responds(to: clientProvidedIdSel),
           let launchReason = (activity as AnyObject).perform(launchReasonSel)?.takeUnretainedValue() as? String,
           launchReason == continuedProcessingReason,
           let source = (activity as AnyObject).perform(clientProvidedIdSel)?.takeUnretainedValue() as? String {

            let destination = hostTaskIdentifier(source)
            let expectedName = continuedProcessingNamePrefix + source
            let currentName = (activity as AnyObject).responds(to: nameSel)
                ? (activity as AnyObject).perform(nameSel)?.takeUnretainedValue() as? String
                : nil

            if destination != source && currentName == expectedName, let nsCoder = coder as? NSCoder {
                let adapter = LCBackgroundTaskCoder(coder: nsCoder, sourceIdentifier: source, destinationIdentifier: destination)
                orig(activity, selector, adapter)
                return
            }
        }

        orig(activity, selector, coder)
    }

    fileprivate static func handleDecodeActivity(activity: AnyObject, selector: Selector, coder: AnyObject) -> AnyObject {
        guard let orig = originalDecodeActivity else { return activity }

        if isXPCCoder(coder, className: "NSXPCDecoder"), let nsCoder = coder as? NSCoder {
            let reason = nsCoder.decodeObject(of: NSString.self, forKey: "launchReason") as? String
            let name = nsCoder.decodeObject(of: NSString.self, forKey: "name") as? String

            if reason == continuedProcessingReason, let taskName = name, taskName.hasPrefix(continuedProcessingNamePrefix) {
                let source = String(taskName.dropFirst(continuedProcessingNamePrefix.count))
                let destination = guestTaskIdentifier(source)

                if destination != source {
                    let adapter = LCBackgroundTaskCoder(coder: nsCoder, sourceIdentifier: source, destinationIdentifier: destination)
                    return orig(activity, selector, adapter)
                }
            }
        }

        return orig(activity, selector, coder)
    }

    fileprivate static func handleCancelTask(scheduler: AnyObject, selector: Selector, identifier: NSString) {
        guard let orig = originalCancelTask else { return }
        orig(scheduler, selector, identifier)

        let destination = hostTaskIdentifier(identifier as String)
        if destination != identifier as String {
            orig(scheduler, selector, destination as NSString)
        }
    }

    fileprivate static func handlePermissibleIdentifier(registry: AnyObject, selector: Selector, identifier: NSString) -> ObjCBool {
        if isGuestTaskIdentifier(identifier as String) {
            return ObjCBool(true)
        }
        if let orig = originalIsPermissibleIdentifier {
            return orig(registry, selector, identifier)
        }
        return ObjCBool(false)
    }
}

// MARK: - Fast-Forwarding XPC Coder Adapter

/// XPC Coder proxy adapter that translates background task identifiers on the wire.
private final class LCBackgroundTaskCoder: NSObject {
    @objc let coder: NSCoder
    @objc let sourceIdentifier: String
    @objc let destinationIdentifier: String

    private static let continuedProcessingPrefix = "bgContinuedProcessing-"

    init(coder: NSCoder, sourceIdentifier: String, destinationIdentifier: String) {
        self.coder = coder
        self.sourceIdentifier = sourceIdentifier
        self.destinationIdentifier = destinationIdentifier
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return (coder as AnyObject).responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        return coder
    }

    override func isKind(of aClass: AnyClass) -> Bool {
        if super.isKind(of: aClass) { return true }
        return (coder as AnyObject).isKind(of: aClass)
    }

    private func translatedObject(_ object: Any?, forKey key: String) -> Any? {
        guard let object = object else { return nil }

        if key == "name", let str = object as? String {
            let sourceName = Self.continuedProcessingPrefix + sourceIdentifier
            if str == sourceName {
                return Self.continuedProcessingPrefix + destinationIdentifier
            }
        } else if key == "userInfo", let dict = object as? [String: Any],
                  let clientID = dict["clientID"] as? String, clientID == sourceIdentifier {
            var mutableDict = dict
            mutableDict["clientID"] = destinationIdentifier
            return mutableDict
        }

        return object
    }

    @objc(encodeObject:forKey:)
    func encodeObject(_ object: Any?, forKey key: String) {
        let translated = translatedObject(object, forKey: key)
        coder.encode(translated, forKey: key)
    }

    @objc(decodeObjectOfClass:forKey:)
    func decodeObject(of aClass: AnyClass, forKey key: String) -> Any? {
        let sel = NSSelectorFromString("decodeObjectOfClass:forKey:")
        var obj: Any?
        if (coder as AnyObject).responds(to: sel) {
            obj = (coder as AnyObject).perform(sel, with: aClass, with: key)?.takeUnretainedValue()
        }
        return translatedObject(obj, forKey: key)
    }

    @objc(decodeObjectOfClasses:forKey:)
    func decodeObject(of classes: NSSet?, forKey key: String) -> Any? {
        let sel = NSSelectorFromString("decodeObjectOfClasses:forKey:")
        var obj: Any?
        if (coder as AnyObject).responds(to: sel) {
            obj = (coder as AnyObject).perform(sel, with: classes, with: key)?.takeUnretainedValue()
        }
        return translatedObject(obj, forKey: key)
    }

    @objc(decodeObjectForKey:)
    func decodeObject(forKey key: String) -> Any? {
        let obj = coder.decodeObject(forKey: key)
        return translatedObject(obj, forKey: key)
    }
}
