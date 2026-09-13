package com.hiennv.flutter_callkit_incoming

import android.os.Bundle

/**
 * Unified callback interface for handling incoming-call events natively.
 * This allows other plugins or services to receive call events
 * even when the Flutter engine is terminated.
 */
interface CallkitEventCallback {

    /**
     * Called when an incoming call is shown, accepted, declined, times out or ends.
     * @param event The type of call event
     * @param callData Bundle containing call information (id, nameCaller, etc.)
     */
    fun onCallEvent(event: CallEvent, callData: Bundle)

    /**
     * Enum representing call events we handle
     */
    enum class CallEvent {
        /** The ring is on screen, whichever path showed it. */
        INCOMING,
        ACCEPT,
        DECLINE,
        /** The ring ran out without an answer. */
        TIMEOUT,
        /** The call ended, or its ring was dismissed because it was cancelled elsewhere. */
        ENDED
    }
}