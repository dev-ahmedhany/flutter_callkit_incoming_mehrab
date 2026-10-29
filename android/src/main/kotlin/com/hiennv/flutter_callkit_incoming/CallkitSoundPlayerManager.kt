package com.hiennv.flutter_callkit_incoming

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.*
import android.text.TextUtils
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger

class CallkitSoundPlayerManager(private val context: Context) {

    companion object {
        private const val TAG = "CallkitSoundPlayer"

        @Volatile
        private var sharedInstance: CallkitSoundPlayerManager? = null

        /**
         * The process-wide ringtone player.
         *
         * The receiver used to build a throwaway player whenever no Flutter engine had
         * attached the plugin. A ring started by one of those could not be stopped by the
         * accept, decline or timeout that went through a different player — and on
         * API 28+ it loops.
         */
        fun shared(context: Context): CallkitSoundPlayerManager =
            sharedInstance ?: synchronized(this) {
                sharedInstance ?: CallkitSoundPlayerManager(context.applicationContext)
                    .also { sharedInstance = it }
            }
    }

    /**
     * Where the ring is started and stopped: one task at a time, never on the main thread.
     *
     * `Ringtone.setAudioAttributes` resets a MediaPlayer, a binder call into the media
     * server that waits for as long as that server is busy. It ran on the main thread while
     * the call was coming in, and a slow media server froze the app into an ANR. A single
     * thread keeps the order callers expect: a stop always runs after the play before it.
     * The player is process-wide, so the thread lives as long as the process.
     */
    private val handler: Handler by lazy {
        val thread = HandlerThread("CallkitSoundPlayer")
        thread.start()
        Handler(thread.looper)
    }

    /**
     * Counts stops, on the caller's thread. A play still queued, or still setting up its
     * ringtone, when a stop is asked for must not start ringing after it.
     */
    private val stops = AtomicInteger()

    // The fields below are touched only on [handler]'s thread.

    private var vibrator: Vibrator? = null
    private var audioManager: AudioManager? = null

    private var ringtone: Ringtone? = null

    private var isPlaying: Boolean = false

    private var screenOffRegistered: Boolean = false


    inner class ScreenOffCallkitIncomingBroadcastReceiver : BroadcastReceiver() {
        // Delivered on [handler]'s thread: see registerScreenOff.
        override fun onReceive(context: Context, intent: Intent) {
            if (isPlaying){
                stop()
            }
        }
    }

    private var screenOffCallkitIncomingBroadcastReceiver = ScreenOffCallkitIncomingBroadcastReceiver()


    /** Starts ringing and vibrating for [data]. Returns at once; the work runs on [handler]. */
    fun play(data: Bundle) {
        val sound = data.getString(CallkitConstants.EXTRA_CALLKIT_RINGTONE_PATH, "")
        val stopsBefore = stops.get()
        post("play") {
            if (stops.get() != stopsBefore) return@post
            isPlaying = true
            prepare()
            playSound(sound, stopsBefore)
            // A stop asked for meanwhile has its release queued behind this task.
            if (stops.get() != stopsBefore) return@post
            playVibrator()
            registerScreenOff()
        }
    }

    /** Stops the ring, including one [play] is still setting up. Returns at once. */
    fun stop() {
        stops.incrementAndGet()
        post("stop") { release() }
    }

    fun destroy() {
        stop()
    }

    private fun post(what: String, work: () -> Unit) {
        handler.post {
            // Off the main thread nothing catches for us, and a ring that cannot sound must
            // not take the app down with it.
            try {
                work()
            } catch (e: Exception) {
                Log.e(TAG, "$what failed", e)
            }
        }
    }

    private fun release() {
        this.isPlaying = false

        ringtone?.stop()
        vibrator?.cancel()
        ringtone = null
        vibrator = null
        if (screenOffRegistered) {
            screenOffRegistered = false
            try {
                context.unregisterReceiver(screenOffCallkitIncomingBroadcastReceiver)
            }catch (_: Exception){}
        }
    }

    private fun registerScreenOff() {
        if (screenOffRegistered) return
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        context.registerReceiver(screenOffCallkitIncomingBroadcastReceiver, filter, null, handler)
        screenOffRegistered = true
    }

    private fun prepare() {
        ringtone?.stop()
        vibrator?.cancel()
    }

    private fun playVibrator() {
        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vibratorManager =
                context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vibratorManager.defaultVibrator
        } else {
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        when (audioManager?.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> {
            }

            else -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(
                        VibrationEffect.createWaveform(
                            longArrayOf(0L, 1000L, 1000L),
                            0
                        ),
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                } else {
                    vibrator?.vibrate(longArrayOf(0L, 1000L, 1000L), 0)
                }
            }
        }
    }

    /** [stopsBefore] is [stops] when the play was asked for. */
    private fun playSound(sound: String?, stopsBefore: Int) {
        val uri = sound?.let { getRingtoneUri(it) }
        if (uri == null) {
            // Failed to get ringtone url, can't play sound
            return
        }
        try {
            ringtone = RingtoneManager.getRingtone(context, uri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val attribution = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setLegacyStreamType(AudioManager.STREAM_RING)
                .build()
                ringtone?.setAudioAttributes(attribution)
            }else {
                ringtone?.streamType = AudioManager.STREAM_RING
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                ringtone?.isLooping = true
            }
            // Setting the ringtone up can wait on the media server for seconds. A stop asked
            // for in that time must not be followed by the ring; its release clears this one.
            if (stops.get() != stopsBefore) return
            ringtone?.play()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun getRingtoneUri(fileName: String): Uri? {
        if (TextUtils.isEmpty(fileName)) {
            return getDefaultRingtoneUri()
        }
        
        // If system_ringtone_default is explicitly requested, bypass resource check
        if (fileName.equals("system_ringtone_default", true)) {
            return getDefaultRingtoneUri(useSystemDefault = true)
        }

        try {
            val resId = context.resources.getIdentifier(fileName, "raw", context.packageName)
            if (resId != 0) {
                return Uri.parse("android.resource://${context.packageName}/$resId")
            }

            // For any other unresolved filename, return the default ringtone
            return getDefaultRingtoneUri()
        } catch (e: Exception) {
            // If anything fails, try to return the system default ringtone
            return getDefaultRingtoneUri()
        }
    }

    private fun getDefaultRingtoneUri(useSystemDefault: Boolean = false): Uri? {
        try {
            if (!useSystemDefault) {
                // First try to use ringtone_default resource if it exists
                val resId = context.resources.getIdentifier("ringtone_default", "raw", context.packageName)
                if (resId != 0) {
                    return Uri.parse("android.resource://${context.packageName}/$resId")
                }
            }

            // Fall back to system default ringtone
            return RingtoneManager.getActualDefaultRingtoneUri(
                context,
                RingtoneManager.TYPE_RINGTONE
            )
        } catch (e: Exception) {
            // getActualDefaultRingtoneUri can throw an exception on some devices
            // for custom ringtones
            return getSafeSystemRingtoneUri()
        }
    }

    private fun getSafeSystemRingtoneUri(): Uri? {
        try {
            val defaultUri = RingtoneManager.getActualDefaultRingtoneUri(
                context,
                RingtoneManager.TYPE_RINGTONE
            )

            val rm = RingtoneManager(context)
            rm.setType(RingtoneManager.TYPE_RINGTONE)
            val cursor = rm.cursor
            if (defaultUri != null && cursor != null) {
                while (cursor.moveToNext()) {
                    val uri = rm.getRingtoneUri(cursor.position)
                    if (uri == defaultUri) {
                        cursor.close()
                        return defaultUri
                    }
                }
            }

            // Default isn't system-provided → fallback to first available
            if (cursor != null && cursor.moveToFirst()) {
                val fallback = rm.getRingtoneUri(cursor.position)
                cursor.close()
                return fallback
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return null
    }
}