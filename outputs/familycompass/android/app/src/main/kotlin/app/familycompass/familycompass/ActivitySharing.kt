package app.familycompass.familycompass

import android.Manifest
import android.app.*
import android.app.job.*
import android.content.*
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.*
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONArray
import java.net.URL
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.HttpsURLConnection

/** Opt-in metadata only. Never inspect Notification.extras, titles, text, actions or images. */
object ActivitySharing {
    private const val CHANNEL = "family_compass_activity"
    private const val NOTICE = 7401
    private const val RETRY = 7402
    private const val CLEANUP = 7403
    private const val DAY = 86_400_000L
    private const val KEY_ALIAS = "fc_activity_config_v1"
    private val worker = Executors.newSingleThreadExecutor()
    private val networkWorker = Executors.newSingleThreadExecutor()
    private val flushing = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    @Volatile var connected = false
    @Volatile private var connection: HttpsURLConnection? = null
    private fun prefs(c: Context) = c.getSharedPreferences("fc_activity_v1", Context.MODE_PRIVATE)
    private fun manager(c: Context) = c.getSystemService(NotificationManager::class.java)
    private fun enabled(c: Context) = prefs(c).getBoolean("enabled", false)
    private fun component(c: Context) = ComponentName(c, ActivitySummaryListener::class.java)
    fun hasAccess(c: Context): Boolean = if (Build.VERSION.SDK_INT >= 27) {
        manager(c).isNotificationListenerAccessGranted(component(c))
    } else {
        Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners")
            ?.split(':')?.any { ComponentName.unflattenFromString(it) == component(c) } == true
    }
    private fun visibleAllowed(c: Context): Boolean =
        (Build.VERSION.SDK_INT < 33 || c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        manager(c).areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 26 || manager(c).getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
    private fun ready(c: Context) = enabled(c) && hasAccess(c) && visibleAllowed(c)
    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)
    private fun hash(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun wrap(config: JSONObject): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return b64(cipher.iv) + "." + b64(cipher.doFinal(config.toString().toByteArray(Charsets.UTF_8)))
    }
    private fun config(c: Context): JSONObject {
        val parts = prefs(c).getString("config", "")!!.split('.')
        check(parts.size == 2) { "Enable activity sharing again." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, decode(parts[0])))
        return JSONObject(String(cipher.doFinal(decode(parts[1])), Charsets.UTF_8))
    }
    private fun seal(data: JSONObject, cfg: JSONObject, id: String, created: Long): JSONObject {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(decode(cfg.getString("key")), "AES"))
        cipher.updateAAD("${cfg.getString("room")}:activity:$id:$created".toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(data.toString().toByteArray(Charsets.UTF_8))
        return JSONObject().put("v", 1).put("nonce", b64(cipher.iv))
            .put("ciphertext", b64(encrypted.copyOfRange(0, encrypted.size - 16)))
            .put("mac", b64(encrypted.copyOfRange(encrypted.size - 16, encrypted.size)))
    }
    fun register(c: Context, messenger: BinaryMessenger) {
        val app = c.applicationContext
        MethodChannel(messenger, "app.familycompass/activity").setMethodCallHandler { call, result ->
            if (call.method == "openAccessSettings") {
                val activity = MediaRuntime.activity.get()
                if (activity == null || !MediaRuntime.visible) result.error("open_app", "Open the child app first.", null)
                else try {
                    activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(null)
                } catch (_: Exception) { result.error("settings", "Open Android Settings and search Notification access.", null) }
                return@setMethodCallHandler
            }
            if (call.method == "stop" || call.method == "reset") {
                stop(app)
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "enable" && !MediaRuntime.visible) {
                result.error("open_app", "Enable sharing on the child phone while its app is open.", null)
                return@setMethodCallHandler
            }
            worker.execute {
                try {
                    when (call.method) {
                        "status" -> {
                            if (enabled(app) && (!hasAccess(app) || !visibleAllowed(app))) stop(app)
                            ActivityDb(app).use { helper -> helper.purge() }
                            val pending = ActivityDb(app).use { it.pending() }
                            val state = mapOf("enabled" to enabled(app), "access" to hasAccess(app), "connected" to connected,
                                "notifications" to visibleAllowed(app), "pending" to pending,
                                "lastUpload" to prefs(app).getLong("lastUpload", 0), "error" to prefs(app).getString("error", ""))
                            main.post { result.success(state) }
                        }
                        "enable" -> {
                            check(hasAccess(app)) { "Grant Android Notification access, then enable sharing here." }
                            check(visibleAllowed(app)) { "Allow visible app notifications first." }
                            val cfg = JSONObject(call.arguments as Map<*, *>)
                            val url = URL(cfg.getString("baseUrl"))
                            check(url.protocol == "https" && url.host.isNotEmpty() && url.userInfo == null && url.query == null && url.ref == null)
                            check(Regex("[a-f0-9]{64}").matches(cfg.getString("room")))
                            check(Regex("[a-f0-9]{64}").matches(cfg.getString("token")))
                            check(decode(cfg.getString("key")).size == 32)
                            val wrapped = wrap(cfg)
                            ActivityDb(app).use { it.clear() }
                            prefs(app).edit().putString("config", wrapped).putBoolean("enabled", true).putLong("since", System.currentTimeMillis())
                                .putString("error", "").putLong("lastUpload", 0).commit()
                            showIndicator(app)
                            scheduleCleanup(app)
                            if (!connected) NotificationListenerService.requestRebind(component(app))
                            main.post { result.success(null) }
                        }
                        else -> main.post { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    android.util.Log.w("FCActivity", "${call.method} failed: ${e.javaClass.simpleName}")
                    main.post { result.error("activity_state", if (e is IllegalStateException) e.message else "Could not update activity sharing. Try again.", null) }
                }
            }
        }
    }
    private fun showIndicator(c: Context) {
        if (!ready(c)) return
        if (Build.VERSION.SDK_INT >= 26) manager(c).createNotificationChannel(
            NotificationChannel(CHANNEL, "Activity sharing status", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getBroadcast(c, NOTICE, Intent(c, ActivitySharingStopReceiver::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(c, NOTICE, Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(c)
        manager(c).notify(NOTICE, builder.setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setContentTitle("Notification activity sharing is on")
            .setContentText("App names and times are shared with your paired parent. Tap Stop to end.")
            .setStyle(Notification.BigTextStyle().bigText("App names and notification times are shared with your paired parent for 24 hours. Message contents are not collected. Stop sharing at any time."))
            .setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PUBLIC).setContentIntent(open)
            .setDeleteIntent(stop).addAction(Notification.Action.Builder(null, "Stop sharing", stop).build()).build())
    }
    fun stop(c: Context) {
        prefs(c).edit().putBoolean("enabled", false).remove("config").putString("error", "").commit()
        connection?.disconnect()
        manager(c).cancel(NOTICE)
        c.getSystemService(JobScheduler::class.java).cancel(RETRY)
        c.getSystemService(JobScheduler::class.java).cancel(CLEANUP)
        worker.execute { ActivityDb(c).use { it.clear() } }
    }
    fun onConnected(c: Context) {
        connected = true
        worker.execute {
            try {
                if (enabled(c) && !ready(c)) stop(c)
                if (ready(c)) { showIndicator(c); scheduleCleanup(c); requestFlush(c) }
            } catch (_: Exception) { prefs(c).edit().putString("error", "Open activity settings and enable sharing again.").apply() }
        }
    }
    fun onDisconnected(c: Context) {
        connected = false
        if (enabled(c) && !hasAccess(c)) stop(c)
    }
    fun posted(c: Context, sbn: StatusBarNotification) {
        // Copy only routing metadata. No message contents are accessed, even transiently.
        if (!enabled(c) || sbn.packageName == c.packageName || sbn.isOngoing ||
            sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val packageName = sbn.packageName.take(255)
        val slot = hash(sbn.key)
        val created = System.currentTimeMillis()
        if (sbn.postTime < prefs(c).getLong("since", created)) return
        worker.execute {
            try {
                if (!ready(c) || manager(c).activeNotifications.none { it.id == NOTICE }) { stop(c); return@execute }
                ActivityDb(c).use { helper ->
                    helper.purge()
                    val db = helper.writableDatabase
                    db.rawQuery("SELECT 1 FROM seen WHERE slot=?", arrayOf(slot)).use { if (it.moveToFirst()) return@execute }
                    if (helper.pending() >= 20000) {
                        prefs(c).edit().putString("error", "Local queue is full. Keep the phone online to resume activity sharing.").apply()
                        return@execute
                    }
                    val label = try { c.packageManager.getApplicationLabel(c.packageManager.getApplicationInfo(packageName, 0)).toString().take(120) } catch (_: Exception) { packageName }
                    val id = hash(UUID.randomUUID().toString())
                    val cfg = config(c)
                    val summary = JSONObject().put("v", 1).put("package", packageName).put("app", label).put("createdAt", created)
                    val event = JSONObject().put("id", id).put("createdAt", created).put("envelope", seal(summary, cfg, id, created))
                    db.beginTransaction()
                    try {
                        db.execSQL("INSERT INTO queue(id,created,body) VALUES(?,?,?)", arrayOf<Any>(id, created, event.toString()))
                        db.execSQL("INSERT OR REPLACE INTO seen(slot,created) VALUES(?,?)", arrayOf<Any>(slot, created))
                        db.setTransactionSuccessful()
                    } finally { db.endTransaction() }
                }
                requestFlush(c)
            } catch (_: Exception) {
                prefs(c).edit().putString("error", "Activity sync paused. Open activity settings to check permissions and internet.").apply()
                if (enabled(c)) scheduleRetry(c)
            }
        }
    }
    fun removed(c: Context, key: String) {
        if (!enabled(c)) return
        val slot = hash(key)
        worker.execute { ActivityDb(c).use { it.writableDatabase.delete("seen", "slot=?", arrayOf(slot)) } }
    }
    private fun scheduleCleanup(c: Context) {
        c.getSystemService(JobScheduler::class.java).schedule(JobInfo.Builder(CLEANUP, ComponentName(c, ActivityUploadJob::class.java)).setPeriodic(15 * 60_000L).build())
    }
    private fun scheduleRetry(c: Context) {
        if (!enabled(c)) return
        val jobs = c.getSystemService(JobScheduler::class.java)
        if (jobs.getPendingJob(RETRY) == null) jobs.schedule(JobInfo.Builder(RETRY, ComponentName(c, ActivityUploadJob::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setBackoffCriteria(30_000L, JobInfo.BACKOFF_POLICY_EXPONENTIAL).build())
    }
    private fun requestFlush(c: Context) {
        scheduleRetry(c)
        if (!flushing.compareAndSet(false, true)) return
        networkWorker.execute {
            try { flush(c) } catch (_: Exception) {
                prefs(c).edit().putString("error", "Activity sync paused. Check internet and reopen activity settings.").apply()
            } finally { flushing.set(false) }
        }
    }
    fun runJob(c: Context, cancelled: AtomicBoolean, finished: (Boolean) -> Unit) {
        networkWorker.execute {
            val pending = try { flush(c) { cancelled.get() } } catch (_: Exception) { enabled(c) }
            main.post { if (!cancelled.get()) finished(pending) }
        }
    }
    /** Returns true if work remains; a single run is bounded to avoid holding a job indefinitely. */
    private fun flush(c: Context, cancelled: () -> Boolean = { false }): Boolean {
        ActivityDb(c).use { helper ->
            helper.purge()
            if (!enabled(c)) return false
            if (cancelled()) return true
            if (!ready(c)) { stop(c); return false }
            val cfg = config(c)
            val savedConfig = prefs(c).getString("config", "")
            repeat(4) {
                if (cancelled()) return true
                if (!ready(c) || prefs(c).getString("config", "") != savedConfig) return false
                val events = JSONArray()
                val ids = mutableListOf<String>()
                helper.readableDatabase.rawQuery("SELECT id,body FROM queue WHERE created>? ORDER BY created LIMIT 25", arrayOf((System.currentTimeMillis() - DAY).toString())).use { cursor ->
                    while (cursor.moveToNext()) { ids.add(cursor.getString(0)); events.put(JSONObject(cursor.getString(1))) }
                }
                if (ids.isEmpty()) return false
                val url = URL(cfg.getString("baseUrl").trimEnd('/') + "/v1/rooms/${cfg.getString("room")}/activity")
                val conn = url.openConnection() as HttpsURLConnection
                connection = conn
                try {
                    conn.requestMethod = "PUT"
                    conn.connectTimeout = 8_000
                    conn.readTimeout = 8_000
                    conn.instanceFollowRedirects = false
                    conn.setRequestProperty("Authorization", "Bearer ${cfg.getString("token")}")
                    conn.setRequestProperty("X-Family-Compass-Client", cfg.getString("deploymentKey"))
                    conn.setRequestProperty("Content-Type", "application/json")
                    val bytes = JSONObject().put("events", events).toString().toByteArray(Charsets.UTF_8)
                    conn.doOutput = true
                    conn.setFixedLengthStreamingMode(bytes.size)
                    if (!ready(c)) return false
                    if (cancelled()) return true
                    conn.outputStream.use { it.write(bytes) }
                    if (conn.responseCode != 204) {
                        prefs(c).edit().putString("error", if (conn.responseCode == 400) "Check this phone's date and time. Activity upload was rejected." else "Relay unavailable. Summaries will retry while less than 24 hours old.").apply()
                        return true
                    }
                    ids.forEach { helper.writableDatabase.delete("queue", "id=?", arrayOf(it)) }
                    prefs(c).edit().putLong("lastUpload", System.currentTimeMillis()).putString("error", "").apply()
                } catch (_: Exception) {
                    if (enabled(c)) prefs(c).edit().putString("error", "Waiting for internet. Summaries retry until their 24-hour expiry.").apply()
                    return true
                } finally { conn.disconnect(); connection = null }
            }
            return helper.pending() > 0
        }
    }
    private class ActivityDb(c: Context) : SQLiteOpenHelper(c, "activity_queue.db", null, 1) {
        override fun onConfigure(db: SQLiteDatabase) {
            // This PRAGMA returns a result row; execSQL rejects it on Android.
            db.rawQuery("PRAGMA secure_delete=ON", null).use { it.moveToFirst() }
        }
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE queue(id TEXT PRIMARY KEY,created INTEGER NOT NULL,body TEXT NOT NULL)")
            db.execSQL("CREATE TABLE seen(slot TEXT PRIMARY KEY,created INTEGER NOT NULL)")
        }
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}
        fun purge() {
            val cutoff = (System.currentTimeMillis() - DAY).toString()
            writableDatabase.delete("queue", "created<=?", arrayOf(cutoff))
            writableDatabase.delete("seen", "created<=?", arrayOf(cutoff))
        }
        fun clear() { writableDatabase.delete("queue", null, null); writableDatabase.delete("seen", null, null) }
        fun pending(): Int = readableDatabase.rawQuery("SELECT count(*) FROM queue WHERE created>?", arrayOf((System.currentTimeMillis() - DAY).toString())).use { it.moveToFirst(); it.getInt(0) }
    }
}

class ActivitySummaryListener : NotificationListenerService() {
    override fun onListenerConnected() { ActivitySharing.onConnected(applicationContext) }
    override fun onListenerDisconnected() { ActivitySharing.onDisconnected(applicationContext) }
    override fun onNotificationPosted(sbn: StatusBarNotification) { ActivitySharing.posted(applicationContext, sbn) }
    override fun onNotificationRemoved(sbn: StatusBarNotification) { ActivitySharing.removed(applicationContext, sbn.key) }
}
class ActivitySharingStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { ActivitySharing.stop(context.applicationContext) }
}
class ActivityUploadJob : JobService() {
    private val runs = mutableMapOf<Int, AtomicBoolean>()
    override fun onStartJob(params: JobParameters): Boolean {
        val cancelled = AtomicBoolean(false)
        runs[params.jobId] = cancelled
        ActivitySharing.runJob(applicationContext, cancelled) { pending ->
            if (runs[params.jobId] === cancelled) { runs.remove(params.jobId); jobFinished(params, pending) }
        }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean { runs.remove(params.jobId)?.set(true); return true }
}
