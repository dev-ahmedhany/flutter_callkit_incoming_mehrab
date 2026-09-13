//
//  CallManager.swift
//  flutter_callkit_incoming
//
//  Created by Hien Nguyen on 07/10/2021.
//

import Foundation
import CallKit

@available(iOS 10.0, *)
class CallManager: NSObject {

    private let callController = CXCallController()
    private var sharedProvider: CXProvider? = nil
    private(set) var calls = [Call]()

    /// The data of outgoing calls Dart asked to start, until CallKit performs the start action.
    private var pendingStarts = [UUID: Data]()

    /// Receives transaction failures as `(type, op, detail, callId)`, so they reach Dart
    /// instead of only the console.
    var reporter: ((_ type: String, _ op: String, _ detail: String, _ callId: String?) -> Void)?


    func setSharedProvider(_ sharedProvider: CXProvider) {
        self.sharedProvider = sharedProvider
    }

    func startCall(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        let handle = CXHandle(type: data.cxHandleType, value: data.getEncryptHandle())
        // Guard against malformed UUID strings — caller layers (Dart, native) sometimes pass
        // app-internal call identifiers that aren't UUID(8-4-4-4-12) shaped. Force-unwrapping
        // here would crash the host process (was the chronic SnowChat "iPhone caller endCall →
        // process dies" symptom before the Dart-side guard was added). Returning is safe: no
        // CallKit call gets registered, and the caller hears `false`.
        guard let uuid = UUID(uuidString: data.uuid) else {
            reporter?("error", "start_call", "invalid UUID '\(data.uuid)'", data.uuid)
            completion?(false)
            return
        }
        pendingStarts[uuid] = data
        let startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.isVideo = data.type > 0
        requestCall(CXTransaction(action: startCallAction), op: "start_call", callId: data.uuid) { ok in
            guard ok else {
                self.pendingStarts[uuid] = nil
                completion?(false)
                return
            }
            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = handle
            callUpdate.supportsDTMF = data.supportsDTMF
            callUpdate.supportsHolding = data.supportsHolding
            callUpdate.supportsGrouping = data.supportsGrouping
            callUpdate.supportsUngrouping = data.supportsUngrouping
            callUpdate.hasVideo = data.type > 0
            callUpdate.localizedCallerName = data.nameCaller
            self.sharedProvider?.reportCall(with: uuid, updated: callUpdate)
            completion?(true)
        }
    }

    /// The data Dart started `uuid` with, handed to the start action once.
    func takePendingStart(_ uuid: UUID) -> Data? {
        return pendingStarts.removeValue(forKey: uuid)
    }

    func muteCall(call: Call, isMuted: Bool, completion: ((Bool) -> Void)? = nil) {
        let action = CXSetMutedCallAction(call: call.uuid, muted: isMuted)
        requestCall(CXTransaction(action: action), op: "mute_call", callId: call.data.uuid, completion: completion)
    }

    func holdCall(call: Call, onHold: Bool, completion: ((Bool) -> Void)? = nil) {
        let action = CXSetHeldCallAction(call: call.uuid, onHold: onHold)
        requestCall(CXTransaction(action: action), op: "hold_call", callId: call.data.uuid, completion: completion)
    }

    func endCall(uuid: UUID, completion: ((Bool) -> Void)? = nil) {
        let action = CXEndCallAction(call: uuid)
        requestCall(CXTransaction(action: action), op: "end_call", callId: uuid.uuidString, completion: completion)
    }

    /// The app's side of the call is connected.
    ///
    /// An outgoing call reports connected. An incoming call answered in CallKit only records
    /// it. One answered in the app while CallKit still shows it ringing is answered in CallKit
    /// too. A call is never answered twice: the answer action makes the app hear ACCEPT again,
    /// and answering on that would loop.
    func connectedCall(uuid: UUID, completion: ((Bool) -> Void)? = nil) {
        guard let call = callWithUUID(uuid: uuid) else {
            reporter?("info", "call_connected", "no such call", uuid.uuidString)
            completion?(false)
            return
        }
        if call.hasConnected {
            completion?(true)
            return
        }
        if call.isOutGoing || call.answered {
            call.hasConnected = true
            completion?(true)
            return
        }
        let answerAction = CXAnswerCallAction(call: uuid)
        requestCall(CXTransaction(action: answerAction), op: "answer_call", callId: call.data.uuid) { ok in
            if ok {
                call.hasConnected = true
            }
            completion?(ok)
        }
    }

    func endCallAlls() {
        for call in callController.callObserver.calls {
            // The observer also lists other apps' calls, which this provider can't end.
            requestCall(
                CXTransaction(action: CXEndCallAction(call: call.uuid)),
                op: "end_all_calls",
                callId: call.uuid.uuidString,
                failureType: "info"
            )
        }
    }

    func activeCalls() -> [[String: Any]] {
        let calls = callController.callObserver.calls
        var json = [[String: Any]]()
        for call in calls {
            let callItem = self.callWithUUID(uuid: call.uuid)
            if(callItem != nil){
                var item: [String: Any] = callItem!.data.toJSON()
                item["accepted"] = callItem?.hasConnected
                json.append(item)
            }else {
                let item: [String: String] = ["id": call.uuid.uuidString]
                json.append(item)
            }
        }
        return json
    }

    private func requestCall(
        _ transaction: CXTransaction,
        op: String,
        callId: String?,
        failureType: String = "error",
        completion: ((Bool) -> Void)? = nil
    ) {
        callController.request(transaction) { error in
            if let error = error as NSError? {
                self.reporter?(failureType, op, "\(error.localizedDescription) (\(error.domain) \(error.code))", callId)
            }
            completion?(error == nil)
        }
    }


    static let callsChangedNotification = Notification.Name("CallsChangedNotification")
    var callsChangedHandler: (() -> Void)?

    func callWithUUID(uuid: UUID) -> Call?{
        guard let idx = calls.firstIndex(where: { $0.uuid == uuid }) else { return nil }
        return calls[idx]
    }

    func addCall(_ call: Call){
        calls.append(call)
        call.stateDidChange = { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.callsChangedHandler?()
            strongSelf.postCallNotification()
        }
        callsChangedHandler?()
        postCallNotification()
    }

    func removeCall(_ call: Call){
        guard let idx = calls.firstIndex(where: { $0 === call }) else { return }
        calls.remove(at: idx)
        callsChangedHandler?()
        postCallNotification()
    }

    func removeAllCalls() {
        calls.removeAll()
        callsChangedHandler?()
        postCallNotification()
    }

    private func postCallNotification(){
        NotificationCenter.default.post(name: type(of: self).callsChangedNotification, object: self)
    }


}
