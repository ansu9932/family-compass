package app.familycompass.familycompass

import android.Manifest
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Notification
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** One engine survives closing the Activity while the visible availability service runs. */
object MediaRuntime {
    private var cachedEngine: FlutterEngine? = null
    lateinit var channel: MethodChannel
    private lateinit var context: Context
    var activity = WeakReference<MainActivity>(null)
    var visible = false
    var available = false
    private const val REQUEST_NOTIFICATION = 7302
    fun hasEngine(): Boolean = cachedEngine != null && ::channel.isInitialized

    fun engine(appContext: Context): FlutterEngine {
        cachedEngine?.let { return it }
        context = appContext.applicationContext
        val engine = FlutterEngine(context)
        cachedEngine = engine
        ChildPin.register(context, engine.dartExecutor.binaryMessenger)
        ActivitySharing.register(context, engine.dartExecutor.binaryMessenger)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "app.familycompass/media_capture")
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "deviceStatus" -> result.success(if (privacyPaused()) null else DeviceStatus.read(context))
                    "permissionStatus" -> result.success(mapOf(
                        "camera" to granted(Manifest.permission.CAMERA),
                        "microphone" to granted(Manifest.permission.RECORD_AUDIO),
                        "notifications" to notificationsAllowed()
                    ))
                    "isAppVisible" -> result.success(visible && !privacyPaused())
                    "stopAllSharing" -> {
                        context.getSharedPreferences("fc_privacy", Context.MODE_PRIVATE).edit().putBoolean("paused", true).commit()
                        ActivitySharing.stop(context)
                        available = false
                        context.stopService(Intent(context, ScreenProjectionForegroundService::class.java))
                        context.stopService(Intent(context, MediaSessionForegroundService::class.java))
                        notifications().cancel(REQUEST_NOTIFICATION)
                        channel.invokeMethod("availabilityStopped", null)
                        result.success(null)
                    }
                    "availabilityStatus" -> result.success(available)
                    "isDeviceLocked" -> result.success((context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked)
                    "openAppSettings" -> activity.get()?.openSettings(result)
                        ?: result.error("open_app", "Open the child app first", null)
                    "requestMediaPermission" -> {
                        val host = activity.get()
                        if (!visible || host == null) result.error("open_app", "Open the child app to grant permission", null)
                        else host.requestMediaPermission(call.argument<String>("permission"), result)
                    }
                    "enableAvailability" -> {
                        check(!ChildPin.isLocked()) { "Unlock the app before enabling availability." }
                        check(visible) { "Open the child app before enabling Keep available." }
                        check(granted(Manifest.permission.CAMERA) && granted(Manifest.permission.RECORD_AUDIO)) {
                            "Allow Camera and Microphone in Child setup first."
                        }
                        check(notificationsAllowed()) { "Enable notifications so availability and capture remain visible." }
                        context.getSharedPreferences("fc_privacy", Context.MODE_PRIVATE).edit().putBoolean("paused", false).commit()
                        startService(Intent(context, MediaSessionForegroundService::class.java)
                            .setAction(MediaSessionForegroundService.ACTION_AVAILABLE))
                        result.success(null)
                    }
                    "disableAvailability" -> {
                        available = false
                        context.stopService(Intent(context, MediaSessionForegroundService::class.java))
                        result.success(null)
                    }
                    "notifyMediaRequest" -> {
                        if (!privacyPaused()) notifyRequest(call.argument<String>("mode") ?: "screen")
                        result.success(null)
                    }
                    "clearMediaRequest" -> {
                        notifications().cancel(REQUEST_NOTIFICATION)
                        result.success(null)
                    }
                    "startCaptureService" -> {
                        check(!privacyPaused()) { "Sharing was stopped on this phone. Unlock it and enable Keep available to resume." }
                        val mode = call.argument<String>("mode")
                        check(mode == "camera" || mode == "microphone") { "Unsupported capture mode" }
                        val activeService = MediaSessionForegroundService.instance
                        if (available && activeService != null) {
                            // Update an already user-started foreground service. Do not start a
                            // new camera/microphone service from the background.
                            activeService.showCapture(mode!!)
                        } else {
                            check(visible) { "Open the child app or enable Keep available before starting media." }
                            startService(Intent(context, MediaSessionForegroundService::class.java)
                                .putExtra(MediaSessionForegroundService.EXTRA_MODE, mode))
                        }
                        result.success(null)
                    }
                    "stopCaptureService" -> {
                        context.stopService(Intent(context, ScreenProjectionForegroundService::class.java))
                        if (available) MediaSessionForegroundService.instance?.showReady()
                        else context.stopService(Intent(context, MediaSessionForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("media_state", e.message ?: "Android could not start the service", null)
            }
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return engine
    }

    private fun startService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
        else context.startService(intent)
    }
    private fun privacyPaused() = context.getSharedPreferences("fc_privacy", Context.MODE_PRIVATE).getBoolean("paused", false)
    fun granted(permission: String) = Build.VERSION.SDK_INT < 23 ||
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    fun notificationsAllowed(): Boolean = (Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS)) &&
        (Build.VERSION.SDK_INT < 24 || notifications().areNotificationsEnabled())
    private fun notifications() = context.getSystemService(NotificationManager::class.java)

    fun openAppIntent(requestCode: Int): PendingIntent = PendingIntent.getActivity(
        context, requestCode,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    private fun notifyRequest(mode: String) {
        if (Build.VERSION.SDK_INT >= 26) notifications().createNotificationChannel(
            NotificationChannel("family_compass_requests", "Parent requests", NotificationManager.IMPORTANCE_HIGH)
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, "family_compass_requests")
            else @Suppress("DEPRECATION") Notification.Builder(context)
        if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(90_000)
        val label = when (mode) { "screen" -> "Screen sharing"; "audio" -> "Microphone"; else -> "Camera" }
        notifications().notify(REQUEST_NOTIFICATION, builder
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("$label requested by your paired parent")
            .setContentText("Tap to open Family Compass and approve the request.")
            .setContentIntent(openAppIntent(REQUEST_NOTIFICATION))
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build())
    }
}
