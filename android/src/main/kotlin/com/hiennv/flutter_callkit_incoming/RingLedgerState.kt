package com.hiennv.flutter_callkit_incoming

/**
 * Pure bookkeeping behind [RingLedger]: what has happened to each incoming call on
 * this device, so every path that can ring agrees on whether one already did.
 *
 * No Android types, so it is unit-testable on the JVM. Not thread-safe on its own;
 * [RingLedger] serialises all access.
 */
class RingLedgerState(
    private val claimLeaseMs: Long = DEFAULT_CLAIM_LEASE_MS,
    private val retainMs: Long = DEFAULT_RETAIN_MS,
) {
    enum class State { CLAIMED, SHOWN, FAILED, ACCEPTED, ENDED, CANCELLED }

    enum class Claim { CLAIMED, DUPLICATE, ENDED }

    data class Entry(val state: State, val source: String, val atMs: Long)

    private val entries = LinkedHashMap<String, Entry>()

    /**
     * Take the right to ring [callId].
     *
     * - [Claim.CLAIMED]: nobody holds it, an earlier claim lapsed without a show, or a
     *   different source tried and failed to show it.
     * - [Claim.DUPLICATE]: another path already claimed or showed it.
     * - [Claim.ENDED]: it was accepted, ended or cancelled here; never ring it again.
     */
    fun claim(callId: String, source: String, nowMs: Long): Claim {
        prune(nowMs)
        val entry = entries[callId]
        if (entry == null) {
            entries[callId] = Entry(State.CLAIMED, source, nowMs)
            return Claim.CLAIMED
        }
        val claimable = when (entry.state) {
            State.CLAIMED -> nowMs - entry.atMs > claimLeaseMs
            State.FAILED -> entry.source != source
            State.SHOWN -> false
            State.ACCEPTED, State.ENDED, State.CANCELLED -> return Claim.ENDED
        }
        if (!claimable) return Claim.DUPLICATE
        entries[callId] = Entry(State.CLAIMED, source, nowMs)
        return Claim.CLAIMED
    }

    /**
     * Marks [callId] SHOWN and returns true, unless it is already showing or finished.
     * A claim by any source does not block the show: claims only decide who tries.
     */
    fun beginShow(callId: String, source: String, nowMs: Long): Boolean {
        prune(nowMs)
        return when (entries[callId]?.state) {
            null, State.CLAIMED, State.FAILED -> {
                entries[callId] = Entry(State.SHOWN, source, nowMs)
                true
            }
            State.SHOWN, State.ACCEPTED, State.ENDED, State.CANCELLED -> false
        }
    }

    /**
     * A claim or show that came to nothing: lets a different source try the same call
     * straight away, instead of waiting out the claim lease with nothing on screen.
     */
    fun markFailed(callId: String, nowMs: Long) {
        val entry = entries[callId] ?: return
        if (entry.state == State.SHOWN || entry.state == State.CLAIMED) {
            entries[callId] = entry.copy(state = State.FAILED, atMs = nowMs)
        }
    }

    /**
     * Records that [callId] is over. A cancel is recorded even before its ring arrives,
     * so the late ring is refused. A cancel never overwrites an accept: the call is live.
     */
    fun markTerminal(callId: String, state: State, nowMs: Long) {
        require(state == State.ACCEPTED || state == State.ENDED || state == State.CANCELLED) {
            "not a terminal state: $state"
        }
        prune(nowMs)
        val existing = entries[callId]
        if (state == State.CANCELLED && existing?.state == State.ACCEPTED) return
        entries[callId] = Entry(state, existing?.source ?: "", nowMs)
    }

    fun stateOf(callId: String, nowMs: Long): State? {
        prune(nowMs)
        return entries[callId]?.state
    }

    /** One entry per line: callId, state, source and time, tab-separated. */
    fun encode(): String = entries.entries
        .filter { (id, entry) -> id.none { it == '\t' || it == '\n' } && entry.source.none { it == '\t' || it == '\n' } }
        .joinToString("\n") { (id, entry) -> "$id\t${entry.state.name}\t${entry.source}\t${entry.atMs}" }

    private fun prune(nowMs: Long) {
        entries.entries.removeAll { nowMs - it.value.atMs > retainMs }
    }

    companion object {
        const val DEFAULT_CLAIM_LEASE_MS = 10_000L
        const val DEFAULT_RETAIN_MS = 10 * 60_000L

        /** Unreadable lines are skipped: a corrupt ledger must never block a ring. */
        fun decode(
            text: String?,
            claimLeaseMs: Long = DEFAULT_CLAIM_LEASE_MS,
            retainMs: Long = DEFAULT_RETAIN_MS,
        ): RingLedgerState {
            val ledger = RingLedgerState(claimLeaseMs, retainMs)
            text?.lineSequence()?.forEach { line ->
                val parts = line.split('\t')
                if (parts.size != 4 || parts[0].isEmpty()) return@forEach
                val state = State.values().firstOrNull { it.name == parts[1] } ?: return@forEach
                val atMs = parts[3].toLongOrNull() ?: return@forEach
                ledger.entries[parts[0]] = Entry(state, parts[2], atMs)
            }
            return ledger
        }
    }
}
