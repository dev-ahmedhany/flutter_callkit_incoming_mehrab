package com.hiennv.flutter_callkit_incoming

import android.Manifest
import android.annotation.SuppressLint
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class CallkitNotificationService : Service() {

    companion object {
        private val foregroundActions = setOf(
            CallkitConstants.ACTION_CALL_START,
            CallkitConstants.ACTION_CALL_ACCEPT
        )

        fun shouldShowOngoingNotification(data: Bundle?): Boolean {
            return data?.getBoolean(CallkitConstants.EXTRA_CALLKIT_CALLING_SHOW, true) == true
        }

        fun requiresOngoingNotificationService(action: String?, data: Bundle?): Boolean {
            return action in foregroundActions && shouldShowOngoingNotification(data)
        }

        fun startServiceWithAction(context: Context, action: String, data: Bundle?) {
            if (!requiresOngoingNotificationService(action, data)) {
                return
            }

            val intent = Intent(context, CallkitNotificationService::class.java).apply {
                this.action = action
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(context, intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopService(context: Context) {
            val intent = Intent(context, CallkitNotificationService::class.java)
            context.stopService(intent)
        }

    }

    private var localSoundPlayerManager: CallkitSoundPlayerManager? = null
    private var localNotificationManager: CallkitNotificationManager? = null

    private fun getCallkitNotificationManager(): CallkitNotificationManager {

        FlutterCallkitIncomingPlugin.getInstance()
            ?.getCallkitNotificationManager()
            ?.let { return it }
        localNotificationManager?.let { return it }
        val soundManager = localSoundPlayerManager
            ?: CallkitSoundPlayerManager(applicationContext).also {
                localSoundPlayerManager = it
            }
        return CallkitNotificationManager(applicationContext, soundManager).also {
            localNotificationManager = it
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        val data = intent?.getBundleExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA)
            ?: run {
                stopSelf(startId)
                return START_NOT_STICKY
            }

        if (!requiresOngoingNotificationService(action, data)) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        getCallkitNotificationManager().createNotificationChanel(data)
        startForegroundCompat(buildPlaceholderNotification(data))

        when (action) {
            CallkitConstants.ACTION_CALL_START,
            CallkitConstants.ACTION_CALL_ACCEPT -> showOngoingCallNotification(data, startId)
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    @SuppressLint("MissingPermission")
    private fun showOngoingCallNotification(bundle: Bundle, startId: Int) {
        val callkitNotification =
            getCallkitNotificationManager().getOnGoingCallNotification(bundle, false)
                ?: run {
                    stopSelf(startId)
                    return
                }
        startForegroundCompat(callkitNotification)
    }

    @SuppressLint("MissingPermission")
    private fun startForegroundCompat(callkitNotification: CallkitNotification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var foregroundServiceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Since Android 14 (API 34), starting a foreground service with the
                // MICROPHONE type throws a SecurityException unless RECORD_AUDIO is
                // already granted — e.g. the user can answer a call before the app
                // has ever requested the mic. Only claim the type when it is allowed.
                if (isPermissionGranted(Manifest.permission.RECORD_AUDIO)) {
                    foregroundServiceType = foregroundServiceType or
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
            }
            startForeground(
                callkitNotification.id,
                callkitNotification.notification,
                foregroundServiceType
            )
        } else {
            startForeground(callkitNotification.id, callkitNotification.notification)
        }
    }

    private fun isPermissionGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun buildPlaceholderNotification(data: Bundle): CallkitNotification {
        val notificationId = getOngoingNotificationId(data)
        val callerName = data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
        val subtitle = data.getString(CallkitConstants.EXTRA_CALLKIT_CALLING_SUBTITLE)
            ?.takeIf { it.isNotBlank() }
            ?: getString(R.string.text_calling)
        val typeCall = data.getInt(CallkitConstants.EXTRA_CALLKIT_TYPE, -1)
        val smallIcon = if (typeCall > 0) {
            R.drawable.ic_video
        } else {
            R.drawable.ic_accept
        }

        val notification = NotificationCompat.Builder(
            this,
            CallkitNotificationManager.NOTIFICATION_CHANNEL_ID_ONGOING
        )
            .setSmallIcon(smallIcon)
            .setContentTitle(callerName)
            .setContentText(subtitle)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .build()

        return CallkitNotification(notificationId, notification)
    }

    private fun getOngoingNotificationId(data: Bundle): Int {
        val callingId = data.getString(
            CallkitConstants.EXTRA_CALLKIT_CALLING_ID,
            data.getString(CallkitConstants.EXTRA_CALLKIT_ID, "callkit_incoming")
        )
        return callingId.hashCode()
    }

    override fun onDestroy() {
        localNotificationManager?.destroy()
        localNotificationManager = null
        localSoundPlayerManager = null
        super.onDestroy()
    }

    override fun onBind(p0: Intent?): IBinder? {
        return null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
        stopSelf()
    }
}
