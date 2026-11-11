package com.localmind.localmind

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
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
 * Main activity for LocalMind.
 *
 * Extends the v2 embedding FlutterFragmentActivity (the FragmentActivity-based
 * host) rather than plain FlutterActivity: plain FlutterActivity extends
 * android.app.Activity, and the v1 embedding was removed from Flutter, so
 * importing `io.flutter.app.FlutterActivity` (v1) fails the build with
 * "use of deleted Android v1 embedding".
 *
 * It also owns three MethodChannels:
 * - `com.localmind.localmind/secure_screen`: while the app's lock is on, notes
 *   must not be captured into screenshots or the recents thumbnail, and that
 *   is a window flag only native code can set.
 * - `clawzilla/apps`: opening and sharing to connected apps, and the list of
 *   launchable apps for adding one. Only packages Aaron connected in Settings
 *   are ever launched or shared to — the Dart side enforces that, this side
 *   just runs the Intent.
 * - `clawzilla/assistant`: the side-button / deep-link launch flag. A
 *   `clawzilla://talk` launch (or ACTION_ASSIST) sets it, and the chat
 *   screen consumes it once to start listening.
 */
class MainActivity : FlutterFragmentActivity() {

    private val secureScreenChannel = "com.localmind.localmind/secure_screen"
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
