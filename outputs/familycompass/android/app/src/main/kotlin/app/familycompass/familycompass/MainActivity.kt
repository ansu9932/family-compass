package app.familycompass.familycompass

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    override fun provideFlutterEngine(context: Context): FlutterEngine = MediaRuntime.engine(context)
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MediaRuntime.activity = WeakReference(this)
    }
    override fun onResume() {
        super.onResume()
        MediaRuntime.visible = true
        MediaRuntime.activity = WeakReference(this)
        MediaRuntime.channel.invokeMethod("appVisible", null)
    }
    override fun onPause() {
        ChildPin.lock()
        MediaRuntime.visible = false
        super.onPause()
    }
    override fun onDestroy() {
        if (MediaRuntime.activity.get() === this) MediaRuntime.activity.clear()
        permissionResult?.error("activity_closed", "Reopen the child app to grant permission", null)
        permissionResult = null
        super.onDestroy()
    }
    fun openSettings(result: MethodChannel.Result) {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        result.success(null)
    }
    fun requestMediaPermission(name: String?, result: MethodChannel.Result) {
        val permission = when (name) {
            "camera" -> Manifest.permission.CAMERA
            "microphone" -> Manifest.permission.RECORD_AUDIO
            "notifications" -> if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null
            else -> null
        }
        if (permission == null || MediaRuntime.granted(permission)) result.success(null)
        else if (permissionResult != null) result.error("busy", "Another permission request is open", null)
        else {
            permissionResult = result
            requestPermissions(arrayOf(permission), 910)
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 910) {
            permissionResult?.success(null)
            permissionResult = null
        }
    }
}
