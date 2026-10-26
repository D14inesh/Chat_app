package com.example.veyon_chat_mobile

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Adds two call features the WebRTC plugin doesn't expose to Dart:
 *  - setFilter: colour filter on the outgoing camera (CallFilterProcessor)
 *  - start/stopScreenShareService: the foreground service Android requires
 *    while the screen is being captured (ScreenShareService)
 */
class MainActivity : FlutterActivity() {
    private val filters = mutableMapOf<String, CallFilterProcessor>()
    private var channel: MethodChannel? = null

    // Something shared into the app, or a widget row tapped — waiting for
    // the Flutter side to pick it up ("takeLaunchItems").
    private var pending: Map<String, Any>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) pending = readLaunch(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val items = readLaunch(intent) ?: return
        // The app is already running: hand it over straight away.
        channel?.invokeMethod("launchItems", items) ?: run { pending = items }
    }

    /** Shared text/files (copied into the app's cache) or a chat to open. */
    private fun readLaunch(intent: Intent?): Map<String, Any>? {
        if (intent == null) return null
        intent.getStringExtra(ChatsWidgetProvider.EXTRA_CHAT)?.let { return mapOf("chatId" to it) }
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return null
        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        }
        val files = uris.take(10).mapNotNull { copyToCache(it) }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (files.isEmpty() && text.isNullOrBlank()) return null
        return mapOf("text" to (text ?: ""), "files" to files)
    }

    private fun copyToCache(uri: Uri): Map<String, String>? = try {
        var name = "shared-file"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0)?.let { name = it }
        }
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val out = File(dir, "${System.currentTimeMillis()}-${name.replace(Regex("[^A-Za-z0-9._-]"), "_")}")
        contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } }
        mapOf("path" to out.absolutePath, "name" to name, "mime" to (contentResolver.getType(uri) ?: "application/octet-stream"))
    } catch (e: Exception) {
        null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "veyon/call")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeLaunchItems" -> {
                    result.success(pending)
                    pending = null
                }
                // Home-screen widget data (unread chats), written by the app.
                "updateWidget" -> {
                    getSharedPreferences(ChatsWidgetProvider.PREFS, MODE_PRIVATE).edit()
                        .putString("data", call.arguments as? String).apply()
                    ChatsWidgetProvider.refreshAll(this)
                    result.success(true)
                }
                "setFilter" -> {
                    val trackId = call.argument<String>("trackId")
                    val filter = call.argument<String>("filter") ?: "none"
                    val track = trackId?.let { FlutterWebRTCPlugin.sharedSingleton?.getLocalTrack(it) } as? LocalVideoTrack
                    if (track == null) {
                        result.success(false)
                    } else {
                        val processor = filters.getOrPut(trackId) { CallFilterProcessor().also { track.addProcessor(it) } }
                        processor.setFilter(filter)
                        result.success(true)
                    }
                }
                "forgetTrack" -> {
                    val trackId = call.argument<String>("trackId")
                    filters.remove(trackId)?.let { p ->
                        (FlutterWebRTCPlugin.sharedSingleton?.getLocalTrack(trackId!!) as? LocalVideoTrack)?.removeProcessor(p)
                    }
                    result.success(true)
                }
                "startScreenShareService" -> {
                    val intent = Intent(this, ScreenShareService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                    result.success(true)
                }
                "stopScreenShareService" -> {
                    stopService(Intent(this, ScreenShareService::class.java))
                    result.success(true)
                }
                // Stable per phone (survives reinstalls) — the server allows
                // one account per device and identifies the phone by this.
                "deviceId" -> result.success(
                    android.provider.Settings.Secure.getString(
                        contentResolver, android.provider.Settings.Secure.ANDROID_ID,
                    ),
                )
                // View-once viewer: no screenshots / screen recording while open.
                "secureScreen" -> {
                    if (call.arguments == true) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
