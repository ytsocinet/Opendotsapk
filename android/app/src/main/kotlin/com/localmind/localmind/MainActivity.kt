package com.localmind.localmind

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Main activity for LocalMind.
 *
 * Extends the v2 embedding FlutterActivity. The v1 embedding was removed from
 * Flutter, so importing `io.flutter.app.FlutterActivity` (v1) fails the build
 * with "use of deleted Android v1 embedding".
 *
 * It also owns three MethodChannels:
 * - `com.localmind.localmind/secure_screen`: while the app's lock is on, notes
 *   must not be captured into screenshots or the recents thumbnail, and that
 *   is a window flag only native code can set.
 * - `clawzilla/apps`: opening and sharing to connected apps, and the system
 *   app picker for adding one. Only packages Aaron connected in Settings
 *   are ever launched or shared to — the Dart side enforces that, this side
 *   just runs the Intent.
 * - `clawzilla/assistant`: the side-button / deep-link launch flag. A
 *   `clawzilla://talk` launch (or ACTION_ASSIST) sets it, and the chat
 *   screen consumes it once to start listening.
 */
class MainActivity : FlutterActivity() {

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

    private var pickAppResult: MethodChannel.Result? = null

    private val pickAppLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val pending = pickAppResult
            pickAppResult = null
            if (pending == null) return@registerForActivityResult
            if (result.resultCode != RESULT_OK) {
                pending.success(null)
                return@registerForActivityResult
            }
            val component = result.data?.component
            if (component == null) {
                pending.success(null)
                return@registerForActivityResult
            }
            val label = try {
                val appInfo =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        packageManager.getApplicationInfo(
                            component.packageName,
                            PackageManager.ApplicationInfoFlags.of(0),
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        packageManager.getApplicationInfo(component.packageName, 0)
                    }
                packageManager.getApplicationLabel(appInfo).toString()
            } catch (e: PackageManager.NameNotFoundException) {
                component.packageName
            }
            pending.success(mapOf("package" to component.packageName, "label" to label))
        }

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
        super.configureFlutterEngine(flutterEngine)
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
                    "pickApp" -> {
                        // The system shows the list of launchable apps; the
                        // app only learns the one package Aaron chose.
                        // No QUERY_ALL_PACKAGES needed.
                        if (pickAppResult != null) {
                            result.error("pick_in_progress", "An app pick is already open", null)
                            return@setMethodCallHandler
                        }
                        pickAppResult = result
                        val launcher = Intent(Intent.ACTION_MAIN).apply {
                            addCategory(Intent.CATEGORY_LAUNCHER)
                        }
                        val chooser = Intent.createChooser(launcher, "Pick an app")
                        try {
                            pickAppLauncher.launch(chooser)
                        } catch (e: ActivityNotFoundException) {
                            pickAppResult = null
                            result.error("no_chooser", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
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
