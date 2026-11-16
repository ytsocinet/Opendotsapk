package com.clawzilla.clawzilla

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Rings a silent set_alarm (build #110).
 *
 * AlarmManager fires this receiver at the alarm time; it plays the
 * alarm tone on loop and posts a notification with a Dismiss action.
 * There is no snooze yet — dismiss stops the tone. A partial wake lock
 * (WAKE_LOCK, normal permission) keeps the phone awake while it rings;
 * it is held at most 10 minutes, then releases itself.
 *
 * Not exported: only explicit intents from this app reach it.
 */
class AlarmReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_FIRE = "com.clawzilla.clawzilla.ALARM_FIRE"
        const val ACTION_DISMISS = "com.clawzilla.clawzilla.ALARM_DISMISS"
        const val EXTRA_LABEL = "label"

        private const val CHANNEL_ID = "clawzilla_alarm"
        private const val NOTIFICATION_ID = 9001
        private const val WAKE_LOCK_TIMEOUT_MS = 10L * 60L * 1000L

        private var player: MediaPlayer? = null
        private var wakeLock: PowerManager.WakeLock? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_DISMISS -> stopRinging(context)
            ACTION_FIRE -> startRinging(
                context,
                intent.getStringExtra(EXTRA_LABEL),
            )
        }
    }

    private fun startRinging(context: Context, label: String?) {
        // Stop any earlier alarm first: two alarms ringing at once would
        // need two players, and the dismiss action could only stop one.
        stopRinging(context)

        val powerManager =
            context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Clawzilla:alarm",
        ).apply { acquire(WAKE_LOCK_TIMEOUT_MS) }

        try {
            val tone = RingtoneManager.getDefaultUri(
                RingtoneManager.TYPE_ALARM,
            ) ?: RingtoneManager.getDefaultUri(
                RingtoneManager.TYPE_NOTIFICATION,
            )
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(
                            AudioAttributes.CONTENT_TYPE_SONIFICATION,
                        )
                        .build(),
                )
                setDataSource(context, tone)
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            // No tone is still an alarm: the notification below is the
            // fallback the user sees. Never crash the receiver.
            Log.e("ClawzillaAlarm", "could not play alarm tone", e)
        }

        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Alarms",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Cypher alarms"
        }
        manager.createNotificationChannel(channel)

        val dismissIntent = Intent(context, AlarmReceiver::class.java).apply {
            action = ACTION_DISMISS
        }
        val dismissPending = PendingIntent.getBroadcast(
            context,
            0,
            dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = Intent(context, MainActivity::class.java)
        val openPending = PendingIntent.getActivity(
            context,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Alarm")
            .setContentText(label ?: "Time to wake up")
            .setContentIntent(openPending)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Dismiss",
                dismissPending,
            )
            .setOngoing(true)
            .setAutoCancel(false)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    private fun stopRinging(context: Context) {
        try {
            player?.stop()
        } catch (_: Exception) {
            // Already stopped; nothing to do.
        }
        try {
            player?.release()
        } catch (_: Exception) {
            // Already released; nothing to do.
        }
        player = null
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
            // Already released; nothing to do.
        }
        wakeLock = null
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
        manager.cancel(NOTIFICATION_ID)
    }
}
