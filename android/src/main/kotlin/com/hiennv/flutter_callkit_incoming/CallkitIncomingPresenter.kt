package com.hiennv.flutter_callkit_incoming

import android.content.Context
import android.os.Bundle
import android.os.Looper
import android.util.Log

/**
 * The single way an incoming call is shown or dismissed on Android.
 *
 * The plugin's INCOMING broadcast, the `showCallkitIncoming` method channel and a host
 * app's native push service all come through here, on the main thread, with
 * [RingLedger] deciding. That gives one notification and one ringtone per call no
 * matter how many of them see the same push.
 */
object CallkitIncomingPresenter {
    private const val TAG = "CallkitIncomingPresenter"

    enum class ShowResult { SHOWN, DUPLICATE, FAILED }

    /**
     * Shows the ring for [data] unless this call is already showing, or was already
     * accepted, ended or cancelled on this device.
     *
     * Call on the main thread — where the plugin's receiver and method channel run — so
     * every show happens in one order. [source] names the caller in the ledger and logs.
     */
    fun show(context: Context, data: Bundle, source: String): ShowResult {
        warnIfNotMainThread("show")
        val app = context.applicationContext
        val callId = data.getString(CallkitConstants.EXTRA_CALLKIT_ID, "")
        if (callId.isNullOrEmpty()) return ShowResult.FAILED

        if (!RingLedger.beginShow(app, callId, source)) {
            Log.w(TAG, "ring $callId already handled on this device; not shown again ($source)")
            return ShowResult.DUPLICATE
        }
        return try {
            CallkitNotificationManager.shared(app).showIncomingNotification(data)
            CallkitEventForwarder.send(CallkitConstants.ACTION_CALL_INCOMING, data)
            addCall(app, Data.fromBundle(data))
            FlutterCallkitIncomingPlugin.notifyEventCallbacks(
                CallkitEventCallback.CallEvent.INCOMING,
                data,
            )
            ShowResult.SHOWN
        } catch (error: Exception) {
            RingLedger.markFailed(app, callId)
            Log.e(TAG, "showing ring $callId failed ($source)", error)
            ShowResult.FAILED
        }
    }

    /**
     * Takes down a ring that was cancelled elsewhere: answered on another device, or the
     * caller hung up. Recorded even when nothing is showing, so a ring that arrives after
     * its own cancel is refused. An accepted call is never dismissed.
     *
     * Unlike `endCall`, no DECLINE is sent: the app reports a DECLINE to the server as the
     * user's own decline. Returns true when a ring was taken down.
     */
    fun dismiss(context: Context, callId: String): Boolean {
        warnIfNotMainThread("dismiss")
        if (callId.isEmpty()) return false
        val app = context.applicationContext
        val call = getDataActiveCalls(app).firstOrNull { it.id == callId }
        if (call?.isAccepted == true) return false

        RingLedger.markTerminal(app, callId, RingLedgerState.State.CANCELLED)
        if (call == null) return false

        val bundle = call.toBundle()
        CallkitNotificationManager.shared(app).clearIncomingNotification(bundle, false)
        removeCall(app, call)
        FlutterCallkitIncomingPlugin.notifyEventCallbacks(
            CallkitEventCallback.CallEvent.ENDED,
            bundle,
        )
        return true
    }

    private fun warnIfNotMainThread(what: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.w(TAG, "$what called off the main thread")
        }
    }
}
