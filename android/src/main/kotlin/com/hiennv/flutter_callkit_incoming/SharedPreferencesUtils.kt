package com.hiennv.flutter_callkit_incoming

import android.content.Context
import android.content.SharedPreferences
import com.fasterxml.jackson.core.type.TypeReference


private const val CALLKIT_PREFERENCES_FILE_NAME = "flutter_callkit_incoming"
private const val ACTIVE_CALLS_KEY = "ACTIVE_CALLS"

/**
 * Serialises every read-modify-write of ACTIVE_CALLS.
 *
 * These helpers used to share one global prefs/editor pair, reassigned on every call,
 * so an add from a push-service thread could interleave with the main thread's remove
 * and lose a call.
 */
private val activeCallsLock = Any()

private fun prefs(context: Context): SharedPreferences =
    context.getSharedPreferences(CALLKIT_PREFERENCES_FILE_NAME, Context.MODE_PRIVATE)

private fun readActiveCalls(context: Context): ArrayList<Data> {
    val json = getString(context, ACTIVE_CALLS_KEY, "[]") ?: "[]"
    return Utils.getGsonInstance()
        .readValue(json, object : TypeReference<ArrayList<Data>>() {})
}


fun addCall(context: Context?, data: Data, isAccepted: Boolean = false) {
    if (context == null) return
    synchronized(activeCallsLock) {
        val arrayData = readActiveCalls(context)
        val currentData = arrayData.find { it == data }
        if (currentData != null) {
            currentData.isAccepted = isAccepted
        } else {
            data.isAccepted = isAccepted
            arrayData.add(data)
        }
        putString(context, ACTIVE_CALLS_KEY, Utils.getGsonInstance().writeValueAsString(arrayData))
    }
}

fun removeCall(context: Context?, data: Data) {
    if (context == null) return
    synchronized(activeCallsLock) {
        val arrayData = readActiveCalls(context)
        arrayData.remove(data)
        putString(context, ACTIVE_CALLS_KEY, Utils.getGsonInstance().writeValueAsString(arrayData))
    }
}

fun removeAllCalls(context: Context?) {
    if (context == null) return
    synchronized(activeCallsLock) {
        remove(context, ACTIVE_CALLS_KEY)
    }
}

fun getDataActiveCalls(context: Context?): ArrayList<Data> {
    if (context == null) return ArrayList()
    synchronized(activeCallsLock) {
        return readActiveCalls(context)
    }
}

fun getDataActiveCallsForFlutter(context: Context?): ArrayList<Map<String, Any?>> {
    if (context == null) return ArrayList()
    val json = synchronized(activeCallsLock) {
        getString(context, ACTIVE_CALLS_KEY, "[]")
    } ?: "[]"
    return Utils.getGsonInstance()
        .readValue(json, object : TypeReference<ArrayList<Map<String, Any?>>>() {})
}

fun putString(context: Context?, key: String, value: String?) {
    if (context == null) return
    prefs(context).edit().putString(key, value).commit()
}

fun getString(context: Context?, key: String, defaultValue: String = ""): String? {
    if (context == null) return null
    return prefs(context).getString(key, defaultValue)
}

fun remove(context: Context?, key: String) {
    if (context == null) return
    prefs(context).edit().remove(key).commit()
}
