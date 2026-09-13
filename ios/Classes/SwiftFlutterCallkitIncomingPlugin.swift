import Flutter
import UIKit
import CallKit
import AVFoundation
import UserNotifications

/// CallKit's audio session, as `SwiftFlutterCallkitIncomingPlugin.audioSessionObserver` sees it.
public enum CallAudioEvent {
    /// A call is being reported or started while no other call holds the audio. CallKit
    /// activates the session only once the call is answered or placed.
    case callStarting
    /// CallKit activated the session: answer, start, resume.
    case activated
    /// CallKit deactivated the session: hold, end.
    case deactivated
    /// The last call is gone.
    case noCalls
}

@available(iOS 10.0, *)
public class SwiftFlutterCallkitIncomingPlugin: NSObject, FlutterPlugin, CXProviderDelegate {

    static let ACTION_DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP = "com.hiennv.flutter_callkit_incoming.DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP"

    static let ACTION_CALL_INCOMING = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_INCOMING"
    static let ACTION_CALL_START = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_START"
    static let ACTION_CALL_ACCEPT = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_ACCEPT"
    static let ACTION_CALL_DECLINE = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_DECLINE"
    static let ACTION_CALL_ENDED = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_ENDED"
    static let ACTION_CALL_TIMEOUT = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TIMEOUT"
    static let ACTION_CALL_CALLBACK = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CALLBACK"
    static let ACTION_CALL_CUSTOM = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CUSTOM"
    static let ACTION_CALL_CONNECTED = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CONNECTED"

    static let ACTION_CALL_TOGGLE_HOLD = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_HOLD"
    static let ACTION_CALL_TOGGLE_MUTE = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_MUTE"
    static let ACTION_CALL_TOGGLE_DMTF = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_DMTF"
    static let ACTION_CALL_TOGGLE_GROUP = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_GROUP"
    static let ACTION_CALL_TOGGLE_AUDIO_SESSION = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_AUDIO_SESSION"

    /// Reports kept while no Dart listener is attached, e.g. for a push that started the app.
    private static let maxPendingReports = 10

    @objc public private(set) static var sharedInstance: SwiftFlutterCallkitIncomingPlugin!

    /// For an app that runs its own audio engine only while CallKit has activated the session
    /// (e.g. LiveKit's engine availability under an external call system). Called on the main
    /// queue.
    public static var audioSessionObserver: ((CallAudioEvent) -> Void)?

    private var streamHandlers: WeakArray<EventCallbackHandler> = WeakArray([])

    private var callManager: CallManager

    private var sharedProvider: CXProvider? = nil

    private var silenceEvents: Bool = false
    private let devicePushTokenVoIP = "DevicePushTokenVoIP"
    private var pendingReports = [[String: Any]]()
    private var hadCalls = false


    private func sendEvent(_ event: String, _ body: [String : Any?]?) {
        if silenceEvents {
            print(event, " silenced")
            return
        } else {
            streamHandlers.reap().forEach { handler in
                handler?.send(event, body ?? [:])
            }
        }

    }

    @objc public func sendEventCustom(_ event: String, body: NSDictionary?) {
        streamHandlers.reap().forEach { handler in
            handler?.send(event, body ?? [:])
        }
    }

    /// A failure (`error`) or notable event (`info`) for the app, sent as ACTION_CALL_CUSTOM
    /// `{type, op, detail, id}`. Never silenced, and kept until Dart listens.
    func report(_ type: String, _ op: String, _ detail: String, callId: String? = nil) {
        NSLog("[CallkitIncoming] \(type) \(op): \(detail) (call \(callId ?? "-"))")
        let body: [String: Any] = ["type": type, "op": op, "detail": detail, "id": callId ?? ""]
        let listening = streamHandlers.reap().compactMap { $0 }.filter { $0.isListening }
        if listening.isEmpty {
            if pendingReports.count == Self.maxPendingReports {
                pendingReports.removeFirst()
            }
            pendingReports.append(body)
            return
        }
        listening.forEach { $0.send(Self.ACTION_CALL_CUSTOM, body) }
    }

    private func flushReports(to handler: EventCallbackHandler) {
        let reports = pendingReports
        pendingReports.removeAll()
        reports.forEach { handler.send(Self.ACTION_CALL_CUSTOM, $0) }
    }

    /// Create `sharedInstance` before any Flutter engine exists.
    ///
    /// Apps that adopt the `UISceneDelegate` lifecycle MUST call this from
    /// `application:didFinishLaunchingWithOptions:` if they handle PushKit VoIP
    /// pushes. Under UIScene, Flutter defers plugin registration until a scene
    /// connects — but a VoIP push relaunches a terminated app *headlessly*: no
    /// scene, no engine, no registration. `sharedInstance` would then still be nil
    /// when `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)` fires, the
    /// call would never be reported to CallKit, and iOS would terminate the app and
    /// eventually stop delivering VoIP pushes altogether.
    ///
    /// This is the pattern Flutter prescribes for APIs that must be configured
    /// before app launch finishes — the plugin exposes a public method the app
    /// calls directly. See
    /// https://docs.flutter.dev/release/breaking-changes/uiscenedelegate
    ///
    /// Idempotent, and order-independent with respect to `register(with:)`, which
    /// attaches the method/event channels to this same instance.
    @objc public static func setup() {
        if sharedInstance == nil {
            sharedInstance = SwiftFlutterCallkitIncomingPlugin()
        }
    }

    public static func sharePluginWithRegister(with registrar: FlutterPluginRegistrar) {
        setup()
        sharedInstance.shareHandlers(with: registrar)
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        sharePluginWithRegister(with: registrar)
    }

    private static func createMethodChannel(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
        return FlutterMethodChannel(name: "flutter_callkit_incoming", binaryMessenger: messenger)
    }

    private static func createEventChannel(messenger: FlutterBinaryMessenger) -> FlutterEventChannel {
        return FlutterEventChannel(name: "flutter_callkit_incoming_events", binaryMessenger: messenger)
    }

    public override init() {
        callManager = CallManager()
        super.init()
        callManager.reporter = { [weak self] type, op, detail, callId in
            self?.report(type, op, detail, callId: callId)
        }
        callManager.callsChangedHandler = { [weak self] in
            guard let self = self else { return }
            let hasCalls = !self.callManager.calls.isEmpty
            if self.hadCalls && !hasCalls {
                SwiftFlutterCallkitIncomingPlugin.audioSessionObserver?(.noCalls)
            }
            self.hadCalls = hasCalls
        }
    }

    /// Retained for source compatibility. The messenger was never used — channels
    /// are wired in `shareHandlers(with:)` from the registrar instead.
    public convenience init(messenger: FlutterBinaryMessenger) {
        self.init()
    }

    private func shareHandlers(with registrar: FlutterPluginRegistrar) {
        registrar.addMethodCallDelegate(self, channel: Self.createMethodChannel(messenger: registrar.messenger()))
        let eventsHandler = EventCallbackHandler()
        eventsHandler.listenStarted = { [weak self] handler in
            self?.flushReports(to: handler)
        }
        self.streamHandlers.append(eventsHandler)
        Self.createEventChannel(messenger: registrar.messenger()).setStreamHandler(eventsHandler)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "showCallkitIncoming":
            if let args = call.arguments as? [String: Any] {
                showCallkitIncoming(Data(args: args), fromPushKit: false)
            }
            result(true)
            break
        case "showMissCallNotification":
            if let args = call.arguments as? [String: Any] {
                self.showMissedCallNotification(Data(args: args))
            }
            result(true)
            break
        case "startCall":
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            self.startCall(Data(args: args), fromPushKit: false) { result($0) }
            break
        case "endCall":
            // Always the call Dart names. After a VoIP push this used to end the pushed call
            // whatever id was passed, so clearing a stale entry killed the ringing call.
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            self.endCall(Data(args: args)) { result($0) }
            break
        case "muteCall":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String,
                  let isMuted = args["isMuted"] as? Bool else {
                result(false)
                return
            }
            self.muteCall(callId, isMuted: isMuted) { result($0) }
            break
        case "isMuted":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String else{
                result(false)
                return
            }
            guard let callUUID = UUID(uuidString: callId),
                  let call = self.callManager.callWithUUID(uuid: callUUID) else {
                result(false)
                return
            }
            result(call.isMuted)
            break
        case "holdCall":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String,
                  let onHold = args["isOnHold"] as? Bool else {
                result(false)
                return
            }
            self.holdCall(callId, onHold: onHold) { result($0) }
            break
        case "callConnected":
            // Always the call Dart names, as for endCall.
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            self.connectedCall(Data(args: args)) { result($0) }
            break
        case "activeCalls":
            result(self.callManager.activeCalls())
            break;
        case "endAllCalls":
            self.callManager.endCallAlls()
            result(true)
            break
        case "getDevicePushTokenVoIP":
            result(self.getDevicePushTokenVoIP())
            break;
        case "silenceEvents":
            guard let silence = call.arguments as? Bool else {
                result(true)
                return
            }

            self.silenceEvents = silence
            result(true)
            break;
        case "requestNotificationPermission":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                self.requestNotificationPermission(getArgs)
            }
            result(true)
            break
         case "requestFullIntentPermission":
            result(true)
            break
         case "canUseFullScreenIntent":
            result(true)
            break
        case "hideCallkitIncoming":
            result(true)
            break
        case "endNativeSubsystemOnly":
            result(true)
            break
        case "setAudioRoute":
            result(true)
            break
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    @objc public func setDevicePushTokenVoIP(_ deviceToken: String) {
        UserDefaults.standard.set(deviceToken, forKey: devicePushTokenVoIP)
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP, ["deviceTokenVoIP":deviceToken])
    }

    @objc public func getDevicePushTokenVoIP() -> String {
        return UserDefaults.standard.string(forKey: devicePushTokenVoIP) ?? ""
    }

    /// The data of the call answered in CallKit and still up, if any.
    @objc public func getAcceptedCall() -> Data? {
        return callManager.calls.first(where: { $0.answered && !$0.hasEnded })?.data
    }

    @objc public func showCallkitIncoming(_ data: Data, fromPushKit: Bool) {
        reportIncomingCall(data, fromPushKit: fromPushKit, completion: nil)
    }

    /// For a VoIP push, call PushKit's completion from `completion`: it runs once CallKit has
    /// the call.
    @objc public func showCallkitIncoming(_ data: Data, fromPushKit: Bool, completion: @escaping () -> Void) {
        reportIncomingCall(data, fromPushKit: fromPushKit, completion: completion)
    }

    private func reportIncomingCall(_ data: Data, fromPushKit: Bool, completion: (() -> Void)?) {
        if(data.isShowMissedCallNotification){
            CallkitNotificationManager.shared.addNotificationCategory(data.missedNotificationCallbackText)
        }

        initCallkitProvider(data)

        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        guard let uuid = UUID(uuidString: data.uuid) else {
            report("error", "report_incoming", "invalid UUID '\(data.uuid)'", callId: data.uuid)
            // iOS terminates an app that doesn't report a VoIP push to CallKit, and stops
            // delivering them if it keeps failing: report a placeholder and end it at once.
            guard fromPushKit, let provider = self.sharedProvider else {
                completion?()
                return
            }
            let placeholder = UUID()
            let update = CXCallUpdate()
            update.localizedCallerName = data.nameCaller
            provider.reportNewIncomingCall(with: placeholder, update: update) { _ in
                provider.reportCall(with: placeholder, endedAt: Date(), reason: .failed)
                completion?()
            }
            return
        }

        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = CXHandle(type: data.cxHandleType, value: data.getEncryptHandle())
        callUpdate.supportsDTMF = data.supportsDTMF
        callUpdate.supportsHolding = data.supportsHolding
        callUpdate.supportsGrouping = data.supportsGrouping
        callUpdate.supportsUngrouping = data.supportsUngrouping
        callUpdate.hasVideo = data.type > 0
        callUpdate.localizedCallerName = data.nameCaller

        // Do NOT configure the audio session before reportNewIncomingCall.
        // When maximumCallsPerCallGroup == 1 and a call is already active, iOS
        // rejects the new call (error != nil). Re-activating the shared
        // AVAudioSession up front would, in that rejected case, still interrupt
        // the active call's audio (e.g. WebRTC breakage). Configure it only once
        // the call is successfully reported.
        self.sharedProvider?.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if let error = error {
                // The same call from the socket and a VoIP push is expected; anything else
                // (Do Not Disturb, blocked, too many calls) is a ring the user never saw.
                let duplicate = (error as? CXErrorCodeIncomingCallError)?.code == .callUUIDAlreadyExists
                self.report(duplicate ? "info" : "error", "report_incoming", "\(error.localizedDescription) (\((error as NSError).code))", callId: data.uuid)
            } else {
                // A ring beside a live call must not take the audio away from it.
                if self.audioCall() == nil {
                    SwiftFlutterCallkitIncomingPlugin.audioSessionObserver?(.callStarting)
                }
                self.configureAudioSession(data)
                let call = Call(uuid: uuid, data: data)
                call.handle = data.handle
                self.callManager.addCall(call)
                self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_INCOMING, data.toJSON())
                self.endCallNotExist(data)
            }
            completion?()
        }
    }


    @objc public func startCall(_ data: Data, fromPushKit: Bool) {
        startCall(data, fromPushKit: fromPushKit, completion: nil)
    }

    /// `completion` hears whether CallKit accepted the start.
    public func startCall(_ data: Data, fromPushKit: Bool, completion: ((Bool) -> Void)?) {
        initCallkitProvider(data)
        self.callManager.startCall(data, completion: completion)
    }

    @objc public func muteCall(_ callId: String, isMuted: Bool) {
        muteCall(callId, isMuted: isMuted, completion: nil)
    }

    public func muteCall(_ callId: String, isMuted: Bool, completion: ((Bool) -> Void)?) {
        guard let uuid = UUID(uuidString: callId),
              let call = self.callManager.callWithUUID(uuid: uuid) else {
            completion?(false)
            return
        }
        if call.isMuted == isMuted {
            self.sendMuteEvent(call.data.uuid, isMuted)
            completion?(true)
        } else {
            self.callManager.muteCall(call: call, isMuted: isMuted, completion: completion)
        }
    }

    @objc public func holdCall(_ callId: String, onHold: Bool) {
        holdCall(callId, onHold: onHold, completion: nil)
    }

    /// `completion` hears whether CallKit agreed, e.g. `false` for a resume it refuses while
    /// another call holds the audio.
    public func holdCall(_ callId: String, onHold: Bool, completion: ((Bool) -> Void)?) {
        guard let uuid = UUID(uuidString: callId),
              let call = self.callManager.callWithUUID(uuid: uuid) else {
            completion?(false)
            return
        }
        if call.isOnHold == onHold {
            self.sendHoldEvent(call.data.uuid, onHold)
            completion?(true)
        } else {
            self.callManager.holdCall(call: call, onHold: onHold, completion: completion)
        }
    }

    @objc public func endCall(_ data: Data) {
        endCall(data, completion: nil)
    }

    /// The end action reports the end to Dart once CallKit performs it.
    public func endCall(_ data: Data, completion: ((Bool) -> Void)?) {
        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        guard let uuid = UUID(uuidString: data.uuid) else {
            report("info", "end_call", "invalid UUID '\(data.uuid)'", callId: data.uuid)
            completion?(false)
            return
        }
        self.callManager.endCall(uuid: uuid, completion: completion)
    }

    @objc public func connectedCall(_ data: Data) {
        connectedCall(data, completion: nil)
    }

    public func connectedCall(_ data: Data, completion: ((Bool) -> Void)?) {
        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        guard let uuid = UUID(uuidString: data.uuid) else {
            report("info", "call_connected", "invalid UUID '\(data.uuid)'", callId: data.uuid)
            completion?(false)
            return
        }
        self.callManager.connectedCall(uuid: uuid, completion: completion)
    }

    @objc public func activeCalls() -> [[String: Any]] {
        return self.callManager.activeCalls()
    }

    @objc public func endAllCalls() {
        self.callManager.endCallAlls()
    }

    public func saveEndCall(_ uuid: String, _ reason: Int) {
        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        // Single guard at top covers all five branches.
        guard let callUuid = UUID(uuidString: uuid) else {
            NSLog("[CallkitIncoming] saveEndCall: invalid UUID '\(uuid)' (reason=\(reason)) — ignored")
            return
        }
        switch reason {
        case 1:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.failed)
            break
        case 2, 6:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.remoteEnded)
            break
        case 3:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.unanswered)
            break
        case 4:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.answeredElsewhere)
            break
        case 5:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.declinedElsewhere)
            break
        default:
            break
        }
    }


    /// Ends a ring nobody answered once its duration is up.
    func endCallNotExist(_ data: Data) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(data.duration)) {
            guard let uuid = UUID(uuidString: data.uuid),
                  let call = self.callManager.callWithUUID(uuid: uuid) else {
                return
            }
            // Only a call still ringing: this call's own state, not whichever call came last.
            if !call.answered && !call.isOutGoing && !call.hasEnded {
                self.callEndTimeout(call)
            }
        }
    }

    func callEndTimeout(_ call: Call) {
        self.saveEndCall(call.data.uuid, 3)
        call.endCall()
        self.callManager.removeCall(call)
        self.showMissedCallNotification(call.data)
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TIMEOUT, call.data.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onTimeOut(call)
        }
    }

    func initCallkitProvider(_ data: Data) {
        if(self.sharedProvider == nil){
            self.sharedProvider = CXProvider(configuration: createConfiguration(data))
            self.sharedProvider?.setDelegate(self, queue: nil)
        } else {
            self.sharedProvider?.configuration = createConfiguration(data)
        }
        self.callManager.setSharedProvider(self.sharedProvider!)
    }

    func createConfiguration(_ data: Data) -> CXProviderConfiguration {
        // init(localizedName:) is deprecated since iOS 14: CallKit shows the
        // app's bundle display name whatever is passed, so data.appName is moot.
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = data.supportsVideo
        configuration.maximumCallGroups = data.maximumCallGroups
        configuration.maximumCallsPerCallGroup = data.maximumCallsPerCallGroup
        configuration.supportedHandleTypes = [data.cxHandleType]
        if #available(iOS 11.0, *) {
            configuration.includesCallsInRecents = data.includesCallsInRecents
        }
        if !data.iconName.isEmpty {
            if let image = UIImage(named: data.iconName) {
                configuration.iconTemplateImageData = image.pngData()
            } else {
                report("info", "provider_icon", "no image named '\(data.iconName)'")
            }
        }
        // "system_ringtone_default" means CallKit's own ringtone: leave ringtoneSound unset.
        if !data.ringtonePath.isEmpty && data.ringtonePath != "system_ringtone_default" {
            configuration.ringtoneSound = data.ringtonePath
        }
        return configuration
    }

    func sendDefaultAudioInterruptionNotificationToStartAudioResource(){
        var userInfo : [AnyHashable : Any] = [:]
        let intrepEndeRaw = AVAudioSession.InterruptionType.ended.rawValue
        userInfo[AVAudioSessionInterruptionTypeKey] = intrepEndeRaw
        userInfo[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: self, userInfo: userInfo)
    }

    /// Configures the audio session with the settings `data`'s call was shown or started
    /// with, unless that call leaves the audio session to the app.
    func configureAudioSession(_ data: Data?){
        guard let data = data, data.configureAudioSession else {
            return
        }
        let session = AVAudioSession.sharedInstance()
        do{
            try session.setCategory(AVAudioSession.Category.playAndRecord, options: [
                .allowBluetoothA2DP,
                .duckOthers,
                .allowBluetoothHFP,
            ])

            try session.setMode(self.getAudioSessionMode(data.audioSessionMode))
            try session.setActive(data.audioSessionActive)
            try session.setPreferredSampleRate(data.audioSessionPreferredSampleRate)
            try session.setPreferredIOBufferDuration(data.audioSessionPreferredIOBufferDuration)
        }catch{
            report("error", "audio_session", "\(error)", callId: data.uuid)
        }
    }

    func getAudioSessionMode(_ audioSessionMode: String?) -> AVAudioSession.Mode {
        var mode = AVAudioSession.Mode.default
        switch audioSessionMode {
        case "gameChat":
            mode = AVAudioSession.Mode.gameChat
            break
        case "measurement":
            mode = AVAudioSession.Mode.measurement
            break
        case "moviePlayback":
            mode = AVAudioSession.Mode.moviePlayback
            break
        case "spokenAudio":
            mode = AVAudioSession.Mode.spokenAudio
            break
        case "videoChat":
            mode = AVAudioSession.Mode.videoChat
            break
        case "videoRecording":
            mode = AVAudioSession.Mode.videoRecording
            break
        case "voiceChat":
            mode = AVAudioSession.Mode.voiceChat
            break
        case "voicePrompt":
            if #available(iOS 12.0, *) {
                mode = AVAudioSession.Mode.voicePrompt
            } else {
                // Fallback on earlier versions
            }
            break
        default:
            mode = AVAudioSession.Mode.default
        }
        return mode
    }

    /// The call CallKit's audio belongs to: an answered or outgoing call still up.
    private func audioCall() -> Call? {
        return callManager.calls.first(where: { !$0.hasEnded && ($0.answered || $0.isOutGoing) })
    }

    /// CallKit dropped every call (e.g. its daemon restarted): each ends for the app too.
    public func providerDidReset(_ provider: CXProvider) {
        report("error", "provider_reset", "CallKit reset the provider with \(callManager.calls.count) call(s)")
        for call in self.callManager.calls {
            call.endCall()
            sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, call.data.toJSON())
        }
        self.callManager.removeAllCalls()
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Dart's start, or else a start from outside the app (Recents, Siri): build it from
        // the action itself.
        let data = callManager.takePendingStart(action.callUUID)
            ?? Data(id: action.callUUID.uuidString, nameCaller: "", handle: action.handle.value, type: action.isVideo ? 1 : 0)
        let call = Call(uuid: action.callUUID, data: data, isOutGoing: true)
        call.handle = action.handle.value
        configureAudioSession(call.data)
        call.hasStartedConnectDidChange = { [weak self, weak call] in
            guard let call = call else { return }
            self?.sharedProvider?.reportOutgoingCall(with: call.uuid, startedConnectingAt: call.connectData)
        }
        call.hasConnectDidChange = { [weak self, weak call] in
            guard let call = call else { return }
            self?.sharedProvider?.reportOutgoingCall(with: call.uuid, connectedAt: call.connectedData)
        }
        if audioCall() == nil {
            SwiftFlutterCallkitIncomingPlugin.audioSessionObserver?(.callStarting)
        }
        self.callManager.addCall(call)
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_START, call.data.toJSON())
        action.fulfill()
        // The call is placed, and the app is connecting it from here.
        call.hasStartedConnecting = true
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else{
            report("error", "answer", "no such call", callId: action.callUUID.uuidString)
            action.fail()
            return
        }
        self.configureAudioSession(call.data)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1200)) { [weak self, weak call] in
            guard let call = call, !call.hasEnded else { return }
            self?.configureAudioSession(call.data)
        }

        call.answered = true
        call.data.isAccepted = true
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ACCEPT, call.data.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onAccept(call, action)
        }else {
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            // CallKit has a call this plugin doesn't track (e.g. from before a restart): end it
            // rather than leave it up, and tell no call in the app about it.
            report("info", "end", "no such call", callId: action.callUUID.uuidString)
            action.fulfill()
            return
        }
        call.endCall()
        self.callManager.removeCall(call)
        // Decline or hang-up is this call's own state, not whichever call came last.
        if !call.isOutGoing && !call.answered {
            sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_DECLINE, call.data.toJSON())
            if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
                appDelegate.onDecline(call, action)
            } else {
                action.fulfill()
            }
        } else {
            sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, call.data.toJSON())
            if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
                appDelegate.onEnd(call, action)
            } else {
                action.fulfill()
            }
        }
    }


    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            report("error", "hold", "no such call", callId: action.callUUID.uuidString)
            action.fail()
            return
        }
        // Hold and mute are separate: resuming must bring back the user's own mute.
        call.isOnHold = action.isOnHold
        sendHoldEvent(call.data.uuid, action.isOnHold)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            report("error", "mute", "no such call", callId: action.callUUID.uuidString)
            action.fail()
            return
        }
        call.isMuted = action.isMuted
        sendMuteEvent(call.data.uuid, action.isMuted)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        guard (self.callManager.callWithUUID(uuid: action.callUUID)) != nil else {
            action.fail()
            return
        }
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_GROUP, [ "id": action.callUUID.uuidString, "callUUIDToGroupWith" : action.callUUIDToGroupWith?.uuidString])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard (self.callManager.callWithUUID(uuid: action.callUUID)) != nil else {
            action.fail()
            return
        }
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_DMTF, [ "id": action.callUUID.uuidString, "digits": action.digits, "type": action.type.rawValue ])
        action.fulfill()
    }


    /// An action CallKit gave up on. It must be neither fulfilled nor failed now. A call whose
    /// start or answer timed out cannot go on, so it ends as failed.
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        let callUUID = (action as? CXCallAction)?.callUUID
        report("error", "action_timeout", String(describing: type(of: action)), callId: callUUID?.uuidString)
        guard let uuid = callUUID,
              let call = self.callManager.callWithUUID(uuid: uuid),
              action is CXStartCallAction || action is CXAnswerCallAction else {
            return
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        call.endCall()
        self.callManager.removeCall(call)
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, call.data.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onTimeOut(call)
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {

        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.didActivateAudioSession(audioSession)
        }
        SwiftFlutterCallkitIncomingPlugin.audioSessionObserver?(.activated)

        let call = audioCall()
        // The nudge that restarts WebRTC's audio after CallKit activates, for an app that
        // leaves the session to this plugin. An app owning its audio engine starts it itself.
        if call?.data.configureAudioSession ?? true {
            sendDefaultAudioInterruptionNotificationToStartAudioResource()
        }
        if call?.hasConnected != true {
            configureAudioSession(call?.data)
        }
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_AUDIO_SESSION, [
            "id": call?.data.uuid ?? "",
            "isActivate": true,
            "isOnHold": call?.isOnHold ?? false,
        ])
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {

        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.didDeactivateAudioSession(audioSession)
        }

        let call = audioCall()
        // A call still up is on hold. With none left the session closed after an end, which
        // CallKit reports after the call is removed: "no calls" again, never a late
        // "deactivated" that would leave the app's engine switched off.
        SwiftFlutterCallkitIncomingPlugin.audioSessionObserver?(call == nil ? .noCalls : .deactivated)
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_AUDIO_SESSION, [
            "id": call?.data.uuid ?? "",
            "isActivate": false,
            "isOnHold": call?.isOnHold ?? false,
        ])
    }

    private func sendMuteEvent(_ id: String, _ isMuted: Bool) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_MUTE, [ "id": id, "isMuted": isMuted ])
    }

    private func sendHoldEvent(_ id: String, _ isOnHold: Bool) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_HOLD, [ "id": id, "isOnHold": isOnHold ])
    }

    @objc public func sendCallbackEvent(_ data: [String: Any]?) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_CALLBACK, data)
    }


    private func requestNotificationPermission(_ map: [String: Any]) {
        CallkitNotificationManager.shared.requestNotificationPermission(map)
    }


    private func showMissedCallNotification(_ data: Data) {
        if(!data.isShowMissedCallNotification){
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(data.nameCaller)"
        content.body = "\(data.missedNotificationSubtitle)"
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = "MISSED_CALL_CATEGORY"
        content.userInfo = data.toJSON()

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

        let request = UNNotificationRequest(
            identifier: data.uuid,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling missed call notification: \(error)")
            } else {
                print("Missed call notification scheduled.")
            }
        }
    }

}

class EventCallbackHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    /// Called when Dart starts listening, to deliver what was kept meanwhile.
    var listenStarted: ((EventCallbackHandler) -> Void)?

    var isListening: Bool {
        return eventSink != nil
    }

    public func send(_ event: String, _ body: Any) {
        let data: [String : Any] = [
            "event": event,
            "body": body
        ]
        eventSink?(data)
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        listenStarted?(self)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
