package com.hiennv.flutter_callkit_incoming

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log

/**
 * Removes the self-managed PhoneAccount earlier versions of this plugin registered.
 *
 * It was backed by an empty ConnectionService and never carried a call. A host app that
 * integrates Telecom (androidx.core:core-telecom) registers its own account, and two
 * self-managed accounts for one app clutter OEM calling settings. The stale one would
 * also point at a class that no longer exists.
 */
internal object LegacyPhoneAccount {
    private const val TAG = "LegacyPhoneAccount"
    private const val PREFERENCES_FILE = "flutter_callkit_incoming"
    private const val REMOVED_KEY = "LEGACY_PHONE_ACCOUNT_REMOVED"
    private const val ACCOUNT_ID = "flutter_callkit_incoming_in_app_call_account"
    private const val SERVICE_CLASS =
        "com.hiennv.flutter_callkit_incoming.CallkitConnectionService"

    fun removeOnce(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val prefs = context.getSharedPreferences(PREFERENCES_FILE, Context.MODE_PRIVATE)
            if (prefs.getBoolean(REMOVED_KEY, false)) return
            val telecom =
                context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
            telecom.unregisterPhoneAccount(
                PhoneAccountHandle(ComponentName(context.packageName, SERVICE_CLASS), ACCOUNT_ID)
            )
            prefs.edit().putBoolean(REMOVED_KEY, true).apply()
        } catch (error: Exception) {
            // Before the first unlock storage is unreadable; the next engine start retries.
            Log.w(TAG, "legacy phone account not removed: $error")
        }
    }
}
