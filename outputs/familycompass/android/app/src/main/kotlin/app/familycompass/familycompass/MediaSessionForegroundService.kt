package app.familycompass.familycompass

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel

class MediaSessionForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Family Compass availability and media", NotificationManager.IMPORTANCE_LOW)
        )
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        if (intent.action == ACTION_STOP) {
            MediaRuntime.available = false
            if (!MediaRuntime.hasEngine()) { stopSelf(); return START_NOT_STICKY }
            MediaRuntime.channel.invokeMethod("availabilityStopped", null, object : MethodChannel.Result {
                override fun success(result: Any?) { stopSelf() }
                override fun error(code: String, message: String?, details: Any?) { stopSelf() }
                override fun notImplemented() { stopSelf() }
            })
            return START_NOT_STICKY
        }
        try {
            if (intent.action == ACTION_AVAILABLE) {
                check(MediaRuntime.visible) { "Open the child app to enable availability." }
                val type = if (Build.VERSION.SDK_INT >= 30)
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
                promote(notification("Family Compass: available to parent",
                    "Paired parent can start camera or microphone. Tap Stop to disable."), type)
                MediaRuntime.available = true
                MediaRuntime.channel.invokeMethod("availabilityChanged", true)
            } else {
                val mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_CAMERA
                require(mode == MODE_CAMERA || mode == MODE_MICROPHONE) { "Unsupported camera/audio mode" }
                // Availability was enabled with BOTH types while the Activity was
                // visible. Updating a session must never downgrade that grant.
                if (MediaRuntime.available) {
                    showCapture(mode)
                    return START_NOT_STICKY
                }
                check(MediaRuntime.visible) { "Open the child app or enable Keep available first." }
                val type = if (Build.VERSION.SDK_INT >= 30) {
                    if (mode == MODE_CAMERA) ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA else ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else 0
                promote(notification("Family Compass is sharing the $mode", "Your paired parent has live access. Tap Stop to end it."), type)
            }
        } catch (e: Exception) {
            MediaRuntime.available = false
            MediaRuntime.channel.invokeMethod("availabilityError", e.message ?: "Android stopped availability")
            stopSelf()
        }
        return START_NOT_STICKY
    }
    private fun promote(notification: Notification, type: Int) {
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, type)
        else startForeground(NOTIFICATION_ID, notification)
    }
    private fun notification(title: String, text: String): Notification {
        val stop = PendingIntent.getService(this, NOTIFICATION_ID,
            Intent(this, MediaSessionForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle(title).setContentText(text)
            .setContentIntent(MediaRuntime.openAppIntent(NOTIFICATION_ID))
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true).setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }
    fun showReady() = getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID,
        notification("Family Compass: available to parent", "Paired parent can start camera or microphone. Tap Stop to disable."))
    fun showCapture(mode: String) = getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID,
        notification("Family Compass is sharing the $mode", "Your paired parent has live access. Tap Stop to end it."))
    override fun onDestroy() {
        instance = null
        MediaRuntime.available = false
        if (MediaRuntime.hasEngine()) MediaRuntime.channel.invokeMethod("availabilityChanged", false)
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    companion object {
        var instance: MediaSessionForegroundService? = null
        const val ACTION_AVAILABLE = "app.familycompass.AVAILABLE"
        const val ACTION_STOP = "app.familycompass.STOP_MEDIA"
        const val EXTRA_MODE = "family_compass_capture_mode"
        const val MODE_CAMERA = "camera"
        const val MODE_MICROPHONE = "microphone"
        const val CHANNEL_ID = "family_compass_live_media"
        const val NOTIFICATION_ID = 7301
    }
}
