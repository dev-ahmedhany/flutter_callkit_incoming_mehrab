package com.hiennv.flutter_callkit_incoming

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log

class CallkitIncomingBroadcastReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "CallkitIncomingReceiver"
        var silenceEvents = false

        fun getIntent(context: Context, action: String, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                this.action = "${context.packageName}.${action}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentIncoming(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_INCOMING}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentStart(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_START}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentAccept(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_ACCEPT}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentDecline(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_DECLINE}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentEnded(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_ENDED}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentTimeout(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_TIMEOUT}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentCallback(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_CALLBACK}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentHeldByCell(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_HELD}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentUnHeldByCell(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_UNHELD}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

        fun getIntentConnected(context: Context, data: Bundle?) =
            Intent(context, CallkitIncomingBroadcastReceiver::class.java).apply {
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_CONNECTED}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }
    }

    private fun getCallkitNotificationManager(context: Context): CallkitNotificationManager =
        CallkitNotificationManager.shared(context)

    private fun markTerminal(context: Context, data: Bundle, state: RingLedgerState.State) {
        val callId = data.getString(CallkitConstants.EXTRA_CALLKIT_ID, "")
        if (!callId.isNullOrEmpty()) RingLedger.markTerminal(context, callId, state)
    }


    @SuppressLint("MissingPermission")
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val data = intent.extras?.getBundle(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA) ?: return
        when (action) {
            "${context.packageName}.${CallkitConstants.ACTION_CALL_INCOMING}" -> {
                // The presenter shows it (or refuses a duplicate) and handles its own errors.
                CallkitIncomingPresenter.show(context, data, "broadcast")
            }

            "${context.packageName}.${CallkitConstants.ACTION_CALL_START}" -> {
                try {
                    CallkitNotificationService.startServiceWithAction(
                        context,
                        CallkitConstants.ACTION_CALL_START,
                        data
                    )
                    sendEventFlutter(CallkitConstants.ACTION_CALL_START, data)
                    addCall(context, Data.fromBundle(data), true)
                } catch (error: Exception) {
                    Log.e(TAG, null, error)
                }
            }

            "${context.packageName}.${CallkitConstants.ACTION_CALL_ACCEPT}" -> {
                try {
                    markTerminal(context, data, RingLedgerState.State.ACCEPTED)
                    FlutterCallkitIncomingPlugin.notifyEventCallbacks(CallkitEventCallback.CallEvent.ACCEPT, data)
                    getCallkitNotificationManager(context).clearIncomingNotification(data, true)
                    CallkitNotificationService.startServiceWithAction(
                        context,
                        CallkitConstants.ACTION_CALL_ACCEPT,
                        data
                    )
                    sendEventFlutter(CallkitConstants.ACTION_CALL_ACCEPT, data)
                    addCall(context, Data.fromBundle(data), true)
                } catch (error: Exception) {
                    Log.e(TAG, null, error)
                }
            }

            "${context.packageName}.${CallkitConstants.ACTION_CALL_DECLINE}" -> {
                try {
                    // Log.d(TAG, "[CALLKIT] 📱 ACTION_CALL_DECLINE")           
                    markTerminal(context, data, RingLedgerState.State.ENDED)
                    // Notify native decline callbacks
                    FlutterCallkitIncomingPlugin.notifyEventCallbacks(CallkitEventCallback.CallEvent.DECLINE, data)
                    // clear notification
                    getCallkitNotificationManager(context).clearIncomingNotification(data, false)
                    // Tell CallkitIncomingActivity to finish (fixes notification-banner decline not closing activity)
                    context.sendBroadcast(CallkitIncomingActivity.getIntentEnded(context, false))
                    sendEventFlutter(CallkitConstants.ACTION_CALL_DECLINE, data)
                    removeCall(context, Data.fromBundle(data))
                } catch (error: Exception) {
                    Log.e(TAG, null, error)
                }
            }

            "${context.packageName}.${CallkitConstants.ACTION_CALL_ENDED}" -> {
                try {
                    markTerminal(context, data, RingLedgerState.State.ENDED)
                    FlutterCallkitIncomingPlugin.notifyEventCallbacks(CallkitEventCallback.CallEvent.ENDED, data)
                    // clear notification and stop service
                    getCallkitNotificationManager(context).clearIncomingNotification(data, false)
                    CallkitNotificationService.stopService(context)
                    // Tell CallkitIncomingActivity to finish (fixes endCall/endAllCalls not closing activity)
                    context.sendBroadcast(CallkitIncomingActivity.getIntentEnded(context, false))
                    sendEventFlutter(CallkitConstants.ACTION_CALL_ENDED, data)
                    removeCall(context, Data.fromBundle(data))
                } catch (error: Exception) {
                    Log.e(TAG, null, error)
                }
            }

            "${context.packageName}.${CallkitConstants.ACTION_CALL_TIMEOUT}" -> {
                try {
                    markTerminal(context, data, RingLedgerState.State.ENDED)
                    FlutterCallkitIncomingPlugin.notifyEventCallbacks(CallkitEventCallback.CallEvent.TIMEOUT, data)
                    // clear notification and show miss notification
                    val notificationManager = getCallkitNotificationManager(context)
                    notificationManager.clearIncomingNotification(data, false)
                    notificationManager.showMissCallNotification(data)
                    sendEventFlutter(CallkitConstants.ACTION_CALL_TIMEOUT, data)
                    removeCall(context, Data.fromBundle(data))
                } catch (error: Exception) {
                    Log.e(TAG, null, error)
                }
            }

            "${context.packageName}.${CallkitConstants.ACTION_CALL_CONNECTED}" -> {
                try {
                    // update notification on going connected
                    getCallkitNotificationManager(context).showOngoingCallNotification(data, true)
                    sendEventFlutter(CallkitConstants.ACTION_CALL_CONNECTED, data)
                } catch (error: Exception) {
                    Log.e(TAG, null, error)
                }
            }

            "${context.packageName}.${CallkitConstants.ACTION_CALL_CALLBACK}" -> {
                try {
                    getCallkitNotificationManager(context).clearMissCallNotification(data)
                    sendEventFlutter(CallkitConstants.ACTION_CALL_CALLBACK, data)
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                        val closeNotificationPanel = Intent(Intent.ACTION_CLOSE_SYSTEM_DIALOGS)
                        context.sendBroadcast(closeNotificationPanel)
                    }
                } catch (error: Exception) {
                    Log.e(TAG, null, error)
                }
            }
        }
    }

    private fun sendEventFlutter(event: String, data: Bundle) =
        CallkitEventForwarder.send(event, data)
}
