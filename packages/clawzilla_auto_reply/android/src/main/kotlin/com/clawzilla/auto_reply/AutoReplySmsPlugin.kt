package com.clawzilla.auto_reply

import android.content.Context
import android.media.AudioManager
import android.provider.ContactsContract
import android.telephony.SmsManager
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of Clawzilla auto-reply (build #123).
 *
 * A plain FlutterPlugin — not a MainActivity channel — on purpose.
 * The auto-reply task runs in a WorkManager background engine
 * (`dev.fluttercommunity.workmanager.BackgroundWorker` creates a bare
 * `FlutterEngine` and never runs MainActivity), so a channel registered
 * in `MainActivity.configureFlutterEngine` does not exist there and a
 * background send would throw MissingPluginException. A plugin is
 * registered by the generated registrant in *every* engine, main and
 * background alike, so `sendSms` and `isInCall` work from the background
 * task. The chat-path `send_sms` tool keeps its own `clawzilla/apps`
 * channel in MainActivity, untouched.
 *
 * Three methods, all small:
 * - `sendSms`: SmsManager send to a bare number, multipart when long.
 *   Same semantics as MainActivity's send ("ok" only when the system
 *   accepted it). The recipient must be a number — the Dart service only
 *   ever passes a rule's stored number, never a contact name.
 * - `isInCall`: `AudioManager.mode` — readable with no permission, so
 *   the "never reply while in a call" guard needs no permission ask.
 * - `listContacts`: device contacts with a number, for the add-rule
 *   picker. Needs READ_CONTACTS (already granted for the SMS name
 *   lookup); a missing grant is a `permission_denied` error, not a crash.
 */
class AutoReplySmsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "clawzilla/auto_reply")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sendSms" -> {
                result.success(
                    sendSms(
                        call.argument<String>("recipient"),
                        call.argument<String>("message"),
                    ),
                )
            }
            "isInCall" -> result.success(isInCall())
            "listContacts" -> {
                try {
                    result.success(listContacts())
                } catch (e: SecurityException) {
                    Log.e(
                        "ClawzillaAutoReply",
                        "listContacts denied (READ_CONTACTS missing)",
                        e,
                    )
                    result.error("permission_denied", e.message, null)
                } catch (e: Exception) {
                    Log.e("ClawzillaAutoReply", "listContacts failed", e)
                    result.error("error", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    /**
     * Send an SMS with SmsManager — no composer, no confirmation. Long
     * messages go out as multipart. Returns "ok", "bad_args", or "error".
     */
    private fun sendSms(recipient: String?, message: String?): String {
        if (recipient.isNullOrEmpty() || message.isNullOrEmpty()) {
            return "bad_args"
        }
        // A number is digits and phone punctuation only, with at least 7
        // digits — anything else is a name, and this channel never
        // resolves names (the Dart service only passes rule numbers).
        val trimmed = recipient.trim()
        val digits = trimmed.filter { it.isDigit() }
        if (digits.length < 7 || !trimmed.all { it.isDigit() || it in "+- ()." }) {
            return "bad_args"
        }
        return try {
            val sms = context.getSystemService(SmsManager::class.java)
                ?: SmsManager.getDefault()
            val parts = sms.divideMessage(message)
            if (parts.size > 1) {
                sms.sendMultipartTextMessage(trimmed, null, parts, null, null)
            } else {
                sms.sendTextMessage(trimmed, null, message, null, null)
            }
            "ok"
        } catch (e: SecurityException) {
            Log.e("ClawzillaAutoReply", "sendSms denied (SEND_SMS missing)", e)
            "error"
        } catch (e: IllegalArgumentException) {
            Log.e("ClawzillaAutoReply", "sendSms bad number: $recipient", e)
            "error"
        }
    }

    /**
     * True while the phone is in a call or another app holds the audio
     * mode in communication. No permission is needed to read the mode.
     */
    private fun isInCall(): Boolean {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val mode = audio.mode
        return mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION
    }

    /**
     * Every contact with a phone number, name-sorted, one row per
     * distinct normalised number (a contact with three numbers appears
     * three times — the picker shows the number, so that is correct).
     * Capped so a huge address book cannot flood the channel.
     */
    private fun listContacts(): List<Map<String, String>> {
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, String>>()
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            ),
            null,
            null,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            )
            val numberIndex = cursor.getColumnIndex(
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )
            while (cursor.moveToNext() && out.size < 500) {
                val name = if (nameIndex >= 0) cursor.getString(nameIndex) else null
                val number = if (numberIndex >= 0) cursor.getString(numberIndex) else null
                if (name.isNullOrBlank() || number.isNullOrBlank()) continue
                val digits = number.filter { it.isDigit() }
                if (digits.length < 7) continue
                if (!seen.add(digits)) continue
                out.add(mapOf("name" to name, "number" to number))
            }
        }
        return out
    }
}
