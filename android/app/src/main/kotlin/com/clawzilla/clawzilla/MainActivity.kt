package com.clawzilla.clawzilla

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.ContentProviderOperation
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.Settings
import android.telephony.SmsManager
import android.util.Log
import android.view.WindowManager
import java.util.Calendar
import java.util.TimeZone
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

// Every Android plugin, registered explicitly (see registerPlugins below).
import com.baseflow.geolocator.GeolocatorPlugin
import com.baseflow.permissionhandler.PermissionHandlerPlugin
import com.csdcorp.speech_to_text.SpeechToTextPlugin
import com.eyedeadevelopment.fluttertts.FlutterTtsPlugin
import com.github.dart_lang.jni.JniPlugin
import com.github.dart_lang.jni_flutter.JniFlutterPlugin
import com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin
import com.kasem.receive_sharing_intent.ReceiveSharingIntentPlugin
import com.llfbandit.record.RecordPlugin
import com.masicai.flutteronnxruntime.FlutterOnnxruntimePlugin
import com.mr.flutter.plugin.filepicker.FilePickerPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.tekartik.sqflite.SqflitePlugin
import com.timebox.native_llama.NativeLlamaPlugin
import dev.fluttercommunity.plus.device_info.DeviceInfoPlusPlugin
import dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin
import dev.fluttercommunity.plus.share.SharePlusPlugin
import dev.fluttercommunity.workmanager.WorkmanagerPlugin
import io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin
import io.flutter.plugins.imagepicker.ImagePickerPlugin
import io.flutter.plugins.localauth.LocalAuthPlugin
import io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin
import io.flutter.plugins.webviewflutter.WebViewFlutterPlugin

/**
 * Main activity for Clawzilla.
 *
 * Extends the v2 embedding FlutterFragmentActivity (the FragmentActivity-based
 * host) rather than plain FlutterActivity: plain FlutterActivity extends
 * android.app.Activity, and the v1 embedding was removed from Flutter, so
 * importing `io.flutter.app.FlutterActivity` (v1) fails the build with
 * "use of deleted Android v1 embedding".
 *
 * It also owns three MethodChannels:
 * - `com.clawzilla.clawzilla/secure_screen`: while the app's lock is on, notes
 *   must not be captured into screenshots or the recents thumbnail, and that
 *   is a window flag only native code can set.
 * - `clawzilla/apps`: opening and sharing to connected apps, the list of
 *   launchable apps for adding one, and the four silent tools (build
 *   #110): SMS via SmsManager, calendar/contact insert via
 *   ContentResolver, alarm via AlarmManager. Only packages Aaron
 *   connected in Settings are ever launched or shared to — the Dart
 *   side enforces that, this side just runs the Intent. The four silent
 *   tools need no connected list: they write directly, with no
 *   confirmation, by Aaron's explicit choice ("I want Cypher to send,
 *   no tap for me").
 * - `clawzilla/assistant`: the side-button / deep-link launch flag. A
 *   `clawzilla://talk` launch (or ACTION_ASSIST) sets it, and the chat
 *   screen consumes it once to start listening.
 */
class MainActivity : FlutterFragmentActivity() {

    private val secureScreenChannel = "com.clawzilla.clawzilla/secure_screen"
    private val appsChannel = "clawzilla/apps"
    private val assistantChannel = "clawzilla/assistant"

    private var assistantChannelHandler: MethodChannel? = null

    /**
     * Set when the app was opened from the assistant gesture or the
     * `clawzilla://talk` deep link. Consumed once by Dart
     * (`consumeListenRequest`); a later resume must not re-trigger it.
     */
    private var listenRequested = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        checkAssistantIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        checkAssistantIntent(intent)
    }

    /**
     * A `clawzilla://talk` deep link or an ACTION_ASSIST intent means "open
     * and start listening". Sets the flag for the cold-start path and, when
     * the engine is already up, tells Dart straight away so a launch while
     * the app is already in the foreground listens too.
     */
    private fun checkAssistantIntent(intent: Intent?) {
        if (intent == null) return
        val isTalkLink =
            intent.action == Intent.ACTION_VIEW &&
                intent.data?.scheme == "clawzilla" &&
                intent.data?.host == "talk"
        val isAssist = intent.action == Intent.ACTION_ASSIST
        if (!isTalkLink && !isAssist) return
        listenRequested = true
        assistantChannelHandler?.invokeMethod("listenRequested", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Do NOT call super.configureFlutterEngine: the generated registrant
        // aborts the whole registration when a single plugin throws an Error
        // (it only catches Exception per plugin), leaving every later plugin
        // unregistered. Seen Nov 8, 2026: the onnxruntime plugin's native
        // load threw, so sqflite (and everything after it) never registered,
        // the database was dead, settings never saved, and the app crashed
        // on the real screens. Register each plugin here instead, one
        // try/catch(Throwable) each, so a bad plugin can't block the rest.
        // Keep this list in sync with the pubspec's Android plugins.
        registerPlugins(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureScreenChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enableSecure" -> {
                        applySecure(true)
                        result.success(null)
                    }
                    "disableSecure" -> {
                        applySecure(false)
                        result.success(null)
                    }
                    "openSecuritySettings" -> {
                        // Fail-closed screen escape hatch: send the user to the
                        // system settings where a screen lock can be set.
                        try {
                            startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_settings_activity", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        val assistant = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            assistantChannel,
        )
        assistantChannelHandler = assistant
        assistant.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeListenRequest" -> {
                    val pending = listenRequested
                    listenRequested = false
                    result.success(pending)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchApp" -> {
                        val pkg = call.argument<String>("package")
                        if (pkg.isNullOrEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(launchApp(pkg))
                    }
                    "shareToApp" -> {
                        val pkg = call.argument<String>("package")
                        val text = call.argument<String>("text")
                        if (pkg.isNullOrEmpty() || text.isNullOrEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(shareToApp(pkg, text))
                    }
                    // Build #110: the four silent tools. Each does the
                    // write directly — no system app, no confirmation.
                    // String results for the ones with more than a yes/no
                    // answer ("ok", "no_number", "exact_alarm_denied",
                    // "error"); booleans elsewhere.
                    "sendSms" -> {
                        val recipient = call.argument<String>("recipient")
                        val message = call.argument<String>("message")
                        if (recipient.isNullOrEmpty() || message.isNullOrEmpty()) {
                            result.success("bad_args")
                            return@setMethodCallHandler
                        }
                        result.success(sendSms(recipient, message))
                    }
                    "insertCalendarEvent" -> {
                        val title = call.argument<String>("title")
                        val beginMillis = call.argument<Long>("beginMillis")
                        val endMillis = call.argument<Long>("endMillis")
                        if (title.isNullOrEmpty() || beginMillis == null || endMillis == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(
                            insertCalendarEvent(
                                title,
                                beginMillis,
                                endMillis,
                                call.argument<String>("location"),
                            ),
                        )
                    }
                    "insertContact" -> {
                        val name = call.argument<String>("name")
                        if (name.isNullOrEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(
                            insertContact(
                                name,
                                call.argument<String>("phone"),
                                call.argument<String>("email"),
                            ),
                        )
                    }
                    "setAlarm" -> {
                        val hour = call.argument<Int>("hour")
                        val minute = call.argument<Int>("minute")
                        if (hour == null || minute == null) {
                            result.success("bad_args")
                            return@setMethodCallHandler
                        }
                        result.success(
                            setAlarm(hour, minute, call.argument<String>("label")),
                        )
                    }
                    "listApps" -> {
                        // Our own list, not the system chooser: the chooser
                        // only showed a short grid (10 apps on Aaron's S23
                        // FE, no scroll, YouTube never offered), so it could
                        // never add the apps he actually uses. The manifest
                        // <queries> entry for the launcher intent is what
                        // makes this return every launchable app — no
                        // QUERY_ALL_PACKAGES needed.
                        result.success(listLaunchableApps())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Registers every Android plugin explicitly, one try/catch(Throwable)
     * each, in the same order the generated registrant used. A plugin whose
     * native load fails (e.g. onnxruntime's) is logged and skipped instead
     * of aborting the rest — that abort is what killed the database in
     * Nov 2026. If a plugin is added to or removed from pubspec.yaml,
     * update this list to match.
     */
    private fun registerPlugins(flutterEngine: FlutterEngine) {
        val plugins = listOf<FlutterPlugin>(
            FilePickerPlugin(),
            DeviceInfoPlusPlugin(),
            FlutterForegroundTaskPlugin(),
            FlutterOnnxruntimePlugin(),
            FlutterAndroidLifecyclePlugin(),
            FlutterSecureStoragePlugin(),
            FlutterTtsPlugin(),
            GeolocatorPlugin(),
            ImagePickerPlugin(),
            JniPlugin(),
            JniFlutterPlugin(),
            LocalAuthPlugin(),
            NativeLlamaPlugin(),
            PackageInfoPlugin(),
            PermissionHandlerPlugin(),
            ReceiveSharingIntentPlugin(),
            RecordPlugin(),
            SharePlusPlugin(),
            SharedPreferencesPlugin(),
            SpeechToTextPlugin(),
            SqflitePlugin(),
            WebViewFlutterPlugin(),
            WorkmanagerPlugin(),
        )
        for (plugin in plugins) {
            try {
                flutterEngine.plugins.add(plugin)
            } catch (t: Throwable) {
                Log.e(
                    "ClawzillaPlugins",
                    "Failed to register ${plugin.javaClass.name}",
                    t,
                )
            }
        }
    }

    /** Open a connected app by package name. False when it has no launcher. */
    private fun launchApp(pkg: String): Boolean {
        return try {
            val intent = packageManager.getLaunchIntentForPackage(pkg)
                ?: return false
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    /**
     * Every launchable app on the phone, sorted by label, for the Connected
     * apps picker. Clawzilla itself is left out — connecting it to itself
     * would be nonsense.
     */
    private fun listLaunchableApps(): List<Map<String, String>> {
        val launcher = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val infos =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.queryIntentActivities(
                    launcher,
                    PackageManager.ResolveInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.queryIntentActivities(launcher, 0)
            }
        return infos
            .mapNotNull { info ->
                val pkg = info.activityInfo?.packageName ?: return@mapNotNull null
                if (pkg == packageName) return@mapNotNull null
                val label = info.loadLabel(packageManager).toString()
                mapOf("package" to pkg, "label" to label)
            }
            .distinctBy { it["package"] }
            .sortedBy { (it["label"] ?: it["package"] ?: "").lowercase() }
    }

    /**
     * Hand text to a connected app's share screen. Android opens that app
     * with the text already in it — the user sees it and confirms or
     * cancels there, so nothing is ever sent silently.
     */
    private fun shareToApp(pkg: String, text: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
                setPackage(pkg)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    /**
     * Send an SMS with SmsManager — no composer, no confirmation. The
     * recipient may be a phone number or a contact name: a name is looked
     * up to its first phone number first. Long messages go out as
     * multipart. Returns "ok", "no_number", or "error".
     */
    private fun sendSms(recipient: String, message: String): String {
        return try {
            val number = resolveSmsNumber(recipient) ?: return "no_number"
            val sms = getSystemService(SmsManager::class.java)
                ?: SmsManager.getDefault()
            val parts = sms.divideMessage(message)
            if (parts.size > 1) {
                sms.sendMultipartTextMessage(number, null, parts, null, null)
            } else {
                sms.sendTextMessage(number, null, message, null, null)
            }
            "ok"
        } catch (e: SecurityException) {
            Log.e("ClawzillaApps", "sendSms denied (SEND_SMS missing)", e)
            "error"
        } catch (e: IllegalArgumentException) {
            Log.e("ClawzillaApps", "sendSms bad number: $recipient", e)
            "error"
        }
    }

    /**
     * A phone number passes through; anything else is treated as a
     * contact name and looked up (first phone number wins). Null when
     * no number can be found. Needs READ_CONTACTS for the lookup.
     */
    private fun resolveSmsNumber(recipient: String): String? {
        val trimmed = recipient.trim()
        // A number is digits and phone punctuation only, with at least 7
        // digits — anything with a letter in it is a name.
        val digits = trimmed.filter { it.isDigit() }
        if (digits.length >= 7 && trimmed.all { it.isDigit() || it in "+- ()." }) {
            return trimmed
        }
        val uri = Uri.withAppendedPath(
            ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI,
            Uri.encode(trimmed),
        )
        return try {
            contentResolver.query(
                uri,
                arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (e: SecurityException) {
            Log.e(
                "ClawzillaApps",
                "resolveSmsNumber denied (READ_CONTACTS missing)",
                e,
            )
            null
        }
    }

    /**
     * Insert a calendar event with ContentResolver — no calendar app,
     * no confirmation. Uses the primary calendar, or the first visible
     * one when no primary is set. Needs READ_CALENDAR (to find the
     * calendar) and WRITE_CALENDAR (to insert).
     */
    private fun insertCalendarEvent(
        title: String,
        beginMillis: Long,
        endMillis: Long,
        location: String?,
    ): Boolean {
        return try {
            val calendars = CalendarContract.Calendars.CONTENT_URI
            var calendarId: Long? = null
            contentResolver.query(
                calendars,
                arrayOf(CalendarContract.Calendars._ID),
                "${CalendarContract.Calendars.IS_PRIMARY}=1",
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) calendarId = cursor.getLong(0)
            }
            if (calendarId == null) {
                contentResolver.query(
                    calendars,
                    arrayOf(CalendarContract.Calendars._ID),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) calendarId = cursor.getLong(0)
                }
            }
            val id = calendarId ?: return false
            val values = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, id)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DTSTART, beginMillis)
                put(CalendarContract.Events.DTEND, endMillis)
                put(
                    CalendarContract.Events.EVENT_TIMEZONE,
                    TimeZone.getDefault().id,
                )
                if (!location.isNullOrEmpty()) {
                    put(CalendarContract.Events.EVENT_LOCATION, location)
                }
            }
            contentResolver.insert(
                CalendarContract.Events.CONTENT_URI,
                values,
            ) != null
        } catch (e: SecurityException) {
            Log.e(
                "ClawzillaApps",
                "insertCalendarEvent denied (calendar permission missing)",
                e,
            )
            false
        } catch (e: Exception) {
            Log.e("ClawzillaApps", "insertCalendarEvent failed", e)
            false
        }
    }

    /**
     * Insert a contact with ContentResolver — no contacts app, no
     * confirmation. Stored locally (no account). Needs WRITE_CONTACTS.
     */
    private fun insertContact(
        name: String,
        phone: String?,
        email: String?,
    ): Boolean {
        return try {
            val ops = ArrayList<ContentProviderOperation>()
            ops.add(
                ContentProviderOperation.newInsert(
                    ContactsContract.RawContacts.CONTENT_URI,
                ).build(),
            )
            ops.add(
                ContentProviderOperation.newInsert(
                    ContactsContract.Data.CONTENT_URI,
                )
                    .withValueBackReference(
                        ContactsContract.Data.RAW_CONTACT_ID,
                        0,
                    )
                    .withValue(
                        ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE,
                    )
                    .withValue(
                        ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME,
                        name,
                    )
                    .build(),
            )
            if (!phone.isNullOrEmpty()) {
                ops.add(
                    ContentProviderOperation.newInsert(
                        ContactsContract.Data.CONTENT_URI,
                    )
                        .withValueBackReference(
                            ContactsContract.Data.RAW_CONTACT_ID,
                            0,
                        )
                        .withValue(
                            ContactsContract.Data.MIMETYPE,
                            ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,
                        )
                        .withValue(
                            ContactsContract.CommonDataKinds.Phone.NUMBER,
                            phone,
                        )
                        .withValue(
                            ContactsContract.CommonDataKinds.Phone.TYPE,
                            ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE,
                        )
                        .build(),
                )
            }
            if (!email.isNullOrEmpty()) {
                ops.add(
                    ContentProviderOperation.newInsert(
                        ContactsContract.Data.CONTENT_URI,
                    )
                        .withValueBackReference(
                            ContactsContract.Data.RAW_CONTACT_ID,
                            0,
                        )
                        .withValue(
                            ContactsContract.Data.MIMETYPE,
                            ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE,
                        )
                        .withValue(
                            ContactsContract.CommonDataKinds.Email.ADDRESS,
                            email,
                        )
                        .withValue(
                            ContactsContract.CommonDataKinds.Email.TYPE,
                            ContactsContract.CommonDataKinds.Email.TYPE_HOME,
                        )
                        .build(),
                )
            }
            contentResolver.applyBatch(ContactsContract.AUTHORITY, ops)
            true
        } catch (e: SecurityException) {
            Log.e(
                "ClawzillaApps",
                "insertContact denied (WRITE_CONTACTS missing)",
                e,
            )
            false
        } catch (e: Exception) {
            Log.e("ClawzillaApps", "insertContact failed", e)
            false
        }
    }

    /**
     * Set an alarm with AlarmManager.setAlarmClock — no clock app, no
     * confirmation. The system shows it as an alarm-clock alarm (status
     * bar icon), and fires AlarmReceiver at the time, which rings the
     * alarm tone. A time already past today rolls to tomorrow. Returns
     * "ok", "exact_alarm_denied", or "error".
     *
     * Exact alarms: USE_EXACT_ALARM (normal, auto-granted on Android
     * 13+) is declared alongside SCHEDULE_EXACT_ALARM, so on this phone
     * (Android 14) the grant is automatic. If the call is still refused
     * for lack of the exact-alarm grant (Android 12 without it), the
     * Settings page for it is opened once and "exact_alarm_denied" is
     * returned — the Dart side tells Aaron to turn it on and ask again.
     */
    private fun setAlarm(hour: Int, minute: Int, label: String?): String {
        return try {
            val now = Calendar.getInstance()
            val trigger = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
                if (timeInMillis <= now.timeInMillis) {
                    add(Calendar.DAY_OF_YEAR, 1)
                }
            }
            val alarmManager =
                getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val fireIntent = Intent(this, AlarmReceiver::class.java).apply {
                action = AlarmReceiver.ACTION_FIRE
                putExtra(AlarmReceiver.EXTRA_LABEL, label)
            }
            val firePending = PendingIntent.getBroadcast(
                this,
                hour * 60 + minute,
                fireIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val showIntent = PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            alarmManager.setAlarmClock(
                AlarmManager.AlarmClockInfo(trigger.timeInMillis, showIntent),
                firePending,
            )
            "ok"
        } catch (e: SecurityException) {
            Log.e("ClawzillaApps", "setAlarm denied (exact alarms off)", e)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    startActivity(
                        Intent(
                            Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                        ).apply {
                            data = Uri.parse("package:$packageName")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        },
                    )
                }
            } catch (_: ActivityNotFoundException) {
                // No settings page to open; the Dart message still says
                // where to turn it on.
            }
            "exact_alarm_denied"
        } catch (e: Exception) {
            Log.e("ClawzillaApps", "setAlarm failed", e)
            "error"
        }
    }

    /**
     * FLAG_SECURE keeps this window out of screenshots and screen recordings.
     * On API 33+ the recents thumbnail is a separate opt-out, so toggle both.
     */
    private fun applySecure(enabled: Boolean) {
        runOnUiThread {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                setRecentsScreenshotEnabled(!enabled)
            }
        }
    }
}
