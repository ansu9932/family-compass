package app.familycompass.familycompass

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel

/** Started only after Android returns an approved MediaProjection result. */
class ScreenProjectionForegroundService : Service() {
    private val binder = Binder()
    private var ready = false

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen sharing", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        if (intent.action == ACTION_STOP) {
            if (!MediaRuntime.hasEngine()) { stopSelf(); return START_NOT_STICKY }
            MediaRuntime.channel.invokeMethod("screenSharingStopped", null, object : MethodChannel.Result {
                override fun success(result: Any?) { stopSelf() }
                override fun error(code: String, message: String?, details: Any?) { stopSelf() }
                override fun notImplemented() { stopSelf() }
            })
            return START_NOT_STICKY
        }
        val stop = PendingIntent.getService(this, NOTIFICATION_ID,
            Intent(this, ScreenProjectionForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else @Suppress("DEPRECATION") Notification.Builder(this)
        val notification = builder.setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Family Compass is sharing the screen")
            .setContentText("Your paired parent can see your screen. Tap Stop to end sharing.")
            .setContentIntent(MediaRuntime.openAppIntent(NOTIFICATION_ID))
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true).setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else startForeground(NOTIFICATION_ID, notification)
            ready = true
        } catch (error: Exception) {
            ready = false
            // A null binding lets the capture caller fail without hanging or
            // starting capture without a valid mediaProjection service.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = if (ready) binder else null

    companion object {
        const val ACTION_STOP = "app.familycompass.STOP_SCREEN"
        const val CHANNEL_ID = "family_compass_screen_sharing"
        const val NOTIFICATION_ID = 7303
    }
}
