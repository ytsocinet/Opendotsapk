package com.clawzilla.clawzilla

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.telephony.SmsMessage
import android.util.Log
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * Inbound SMS for auto-reply (build #123, Auto-reply Piece A).
 *
 * Android delivers the `SMS_RECEIVED` broadcast to any app holding
 * `RECEIVE_SMS`; the message PDUs ride in the intent extras, so no
 * `READ_SMS` permission and no inbox query are needed — the app never
 * reads Aaron's messages, it only sees the one that just arrived.
 *
 * This receiver does exactly two things, then gets out of the way
 * (Android kills slow receivers): reconstruct the sender, body, and
 * timestamp from the PDUs, and enqueue a one-off WorkManager task that
 * the Dart `callbackDispatcher` runs as `auto_reply`. No sending and no
 * rules in Kotlin — matching, guards, and the send all live in Dart
 * (`lib/data/services/auto_reply_service.dart`), next to the one send
 * path and the one test suite.
 *
 * The task is enqueued as unique work keyed on sender + timestamp with
 * KEEP, so a redelivered broadcast does not send twice: the second
 * enqueue is dropped. The input data uses the workmanager plugin's own
 * keys (`DART_TASK`, `UNIQUE_NAME`, `payload_*`), exactly as its Dart
 * `registerOneOffTask` writes them, so the Dart side receives
 * `inputData` `{sender, body, timestamp}` unchanged.
 *
 * No group MMS: MMS arrives on `WAP_PUSH_RECEIVED`, which this
 * receiver does not register for, so group texts never trigger it.
 * No inbox: the body is handed to the Dart task, which matches on the
 * sender and drops it — nothing here stores it.
 *
 * Exported must be true: this is a system broadcast, and Android 12+
 * requires the export flag to be explicit.
 */
class SmsReceiver : BroadcastReceiver() {

    companion object {
        private const val ACTION_SMS_RECEIVED =
            "android.provider.Telephony.SMS_RECEIVED"
        private const val DART_TASK_KEY =
            "dev.fluttercommunity.workmanager.DART_TASK"
        private const val UNIQUE_NAME_KEY =
            "dev.fluttercommunity.workmanager.UNIQUE_NAME"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_SMS_RECEIVED) return
        try {
            val extras = intent.extras ?: return
            val pdus = extras.get("pdus") as? Array<*> ?: return
            val format = extras.getString("format")

            // A long text arrives as several PDUs with the same sender and
            // timestamp; the bodies concatenate in order.
            var sender: String? = null
            val body = StringBuilder()
            var timestamp = System.currentTimeMillis()
            for (pdu in pdus) {
                val bytes = pdu as? ByteArray ?: continue
                val message = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    SmsMessage.createFromPdu(bytes, format)
                } else {
                    @Suppress("DEPRECATION")
                    SmsMessage.createFromPdu(bytes)
                }
                if (sender == null) sender = message.displayOriginatingAddress
                body.append(message.messageBody)
                timestamp = message.timestampMillis
            }
            val from = sender?.takeIf { it.isNotBlank() } ?: return

            val uniqueName =
                "auto-reply-${from.filter { it.isDigit() }}-$timestamp"
            val data = Data.Builder()
                .putString(DART_TASK_KEY, "auto_reply")
                .putString(UNIQUE_NAME_KEY, uniqueName)
                .putString("payload_sender", from)
                .putString("payload_body", body.toString())
                .putLong("payload_timestamp", timestamp)
                .build()
            val request = OneTimeWorkRequestBuilder<BackgroundWorker>()
                .setInputData(data)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                uniqueName,
                ExistingWorkPolicy.KEEP,
                request,
            )
        } catch (e: Exception) {
            // A receiver must never crash the broadcast: a failed enqueue
            // means no reply for this message, not a dead phone.
            Log.e("ClawzillaSms", "SMS_RECEIVED handling failed", e)
        }
    }
}
