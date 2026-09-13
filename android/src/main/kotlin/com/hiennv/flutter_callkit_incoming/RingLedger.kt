package com.hiennv.flutter_callkit_incoming

import android.content.Context
import android.util.Log

/**
 * The one record, per process and persisted, of which incoming calls this device has
 * rung and how each ended.
 *
 * Several paths can try to ring the same call: the host app's native push service, a
 * Dart isolate cold-started for the same push, the main isolate reacting to a socket
 * event, and this plugin's own INCOMING broadcast. Claims and shows all go through here
 * under one lock, so exactly one of them rings — and a call that was already accepted,
 * ended or cancelled on this device never rings again.
 *
 * Stored in the same preferences file as ACTIVE_CALLS so a cold-started process still
 * knows. Before the user first unlocks the device, credential-protected storage is
 * unavailable; the ledger then lives in memory rather than throwing.
 */
object RingLedger {
    private const val TAG = "RingLedger"
    private const val PREFERENCES_FILE = "flutter_callkit_incoming"
    private const val KEY = "RING_LEDGER"

    private val lock = Any()
    private var state: RingLedgerState? = null

    fun claim(context: Context, callId: String, source: String): RingLedgerState.Claim =
        update(context) { it.claim(callId, source, now()) }

    fun beginShow(context: Context, callId: String, source: String): Boolean =
        update(context) { it.beginShow(callId, source, now()) }

    fun markFailed(context: Context, callId: String) =
        update(context) { it.markFailed(callId, now()) }

    fun markTerminal(context: Context, callId: String, terminal: RingLedgerState.State) =
        update(context) { it.markTerminal(callId, terminal, now()) }

    fun stateOf(context: Context, callId: String): RingLedgerState.State? =
        synchronized(lock) { load(context).stateOf(callId, now()) }

    private inline fun <T> update(context: Context, block: (RingLedgerState) -> T): T =
        synchronized(lock) {
            val ledger = load(context)
            val result = block(ledger)
            persist(context, ledger)
            result
        }

    private fun load(context: Context): RingLedgerState {
        state?.let { return it }
        val text = try {
            context.applicationContext
                .getSharedPreferences(PREFERENCES_FILE, Context.MODE_PRIVATE)
                .getString(KEY, null)
        } catch (error: Exception) {
            Log.w(TAG, "ring ledger unreadable, starting empty: $error")
            null
        }
        return RingLedgerState.decode(text).also { state = it }
    }

    private fun persist(context: Context, ledger: RingLedgerState) {
        try {
            context.applicationContext
                .getSharedPreferences(PREFERENCES_FILE, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY, ledger.encode())
                .apply()
        } catch (error: Exception) {
            Log.w(TAG, "ring ledger not persisted: $error")
        }
    }

    private fun now() = System.currentTimeMillis()
}
