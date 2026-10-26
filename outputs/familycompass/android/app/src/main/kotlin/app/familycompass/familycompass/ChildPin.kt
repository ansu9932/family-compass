package app.familycompass.familycompass

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec

/** Local app-access PIN. Does not control Android uninstall, device administration or OS settings. */
object ChildPin {
    private const val KEY_ALIAS = "fc_child_pin_v1"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private lateinit var app: Context
    private lateinit var channel: MethodChannel
    @Volatile private var unlocked = false
    @Volatile private var generation = 0L
    private fun prefs() = app.getSharedPreferences("fc_child_pin_v1", Context.MODE_PRIVATE)
    private fun configured() = prefs().contains("record")
    fun isLocked() = ::app.isInitialized && configured() && !unlocked
    fun lock() {
        generation++
        unlocked = false
        if (::channel.isInitialized) channel.invokeMethod("changed", null)
    }
    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun bytes(s: String) = Base64.decode(s, Base64.NO_WRAP)
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun wrap(value: JSONObject): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return b64(cipher.iv) + "." + b64(cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8)))
    }
    private fun record(): JSONObject {
        val p = prefs().getString("record", "")!!.split('.')
        check(p.size == 2) { "PIN storage is unavailable. Use Android app settings to reset the app and pair again." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes(p[0])))
        return JSONObject(String(cipher.doFinal(bytes(p[1])), Charsets.UTF_8))
    }
    private fun derive(pin: CharArray, salt: ByteArray, algorithm: String, iterations: Int): ByteArray {
        val spec = PBEKeySpec(pin, salt, iterations, 256)
        try { return SecretKeyFactory.getInstance(algorithm).generateSecret(spec).encoded }
        finally { spec.clearPassword(); pin.fill('\u0000') }
    }
    private fun boot() = Settings.Global.getInt(app.contentResolver, Settings.Global.BOOT_COUNT, -1)
    private fun remaining(): Long {
        val p = prefs()
        val now = if (p.getInt("boot", -2) == boot()) SystemClock.elapsedRealtime() else System.currentTimeMillis()
        val until = if (p.getInt("boot", -2) == boot()) p.getLong("untilElapsed", 0) else p.getLong("untilWall", 0)
        return ((until - now + 999) / 1000).coerceIn(0, 900)
    }
    private fun status() = mapOf("configured" to configured(), "unlocked" to (!configured() || unlocked), "remaining" to remaining())
    private fun failed() {
        val count = (prefs().getInt("failures", 0) + 1).coerceAtMost(30)
        val delay = if (count < 5) 0L else (30_000L * (1L shl ((count - 5) / 3).coerceAtMost(5))).coerceAtMost(900_000L)
        prefs().edit().putInt("failures", count).putInt("boot", boot()).putLong("untilElapsed", SystemClock.elapsedRealtime() + delay)
            .putLong("untilWall", System.currentTimeMillis() + delay).commit()
    }
    private fun clearFailures() { prefs().edit().remove("failures").remove("untilElapsed").remove("untilWall").commit() }
    private fun matches(pin: String): Boolean {
        check(remaining() == 0L) { "Too many attempts. Try again in ${remaining()} seconds." }
        val r = record()
        val algorithm = r.getString("algorithm")
        val iterations = r.getInt("iterations")
        check(algorithm in listOf("PBKDF2WithHmacSHA256", "PBKDF2WithHmacSHA1") && iterations in 600_000..1_300_000)
        val actual = derive(pin.toCharArray(), bytes(r.getString("salt")), algorithm, iterations)
        val okay = MessageDigest.isEqual(actual, bytes(r.getString("hash")))
        actual.fill(0)
        if (okay) clearFailures() else failed()
        return okay
    }
    fun register(context: Context, messenger: BinaryMessenger) {
        app = context.applicationContext
        channel = MethodChannel(messenger, "app.familycompass/child_pin")
        channel.setMethodCallHandler { call, result ->
            if (call.method == "lock") { lock(); result.success(null); return@setMethodCallHandler }
            val revision = generation
            worker.execute {
                try {
                    when (call.method) {
                        "status" -> main.post { result.success(status()) }
                        "verify" -> {
                            check(MediaRuntime.visible) { "Open the app to enter the PIN." }
                            val okay = configured() && matches(call.argument<String>("pin") ?: "")
                            main.post {
                                unlocked = okay && MediaRuntime.visible && revision == generation
                                result.success(status() + mapOf("accepted" to unlocked))
                                channel.invokeMethod("changed", null)
                            }
                        }
                        "setPin" -> {
                            check(MediaRuntime.visible && !isLocked()) { "Unlock the app before changing its PIN." }
                            if (configured()) check(matches(call.argument<String>("oldPin") ?: "")) { "Current PIN is incorrect." }
                            val pin = call.argument<String>("pin") ?: ""
                            check(Regex("[0-9]{6}").matches(pin)) { "Use a six-digit PIN." }
                            val salt = ByteArray(32).also { SecureRandom().nextBytes(it) }
                            val algorithm = if (Build.VERSION.SDK_INT >= 26) "PBKDF2WithHmacSHA256" else "PBKDF2WithHmacSHA1"
                            val iterations = if (Build.VERSION.SDK_INT >= 26) 600_000 else 1_300_000
                            val hash = derive(pin.toCharArray(), salt, algorithm, iterations)
                            val encoded = wrap(JSONObject().put("v", 1).put("salt", b64(salt)).put("hash", b64(hash)).put("algorithm", algorithm).put("iterations", iterations))
                            hash.fill(0)
                            check(MediaRuntime.visible && revision == generation) { "App was closed. Open it and set the PIN again." }
                            prefs().edit().putString("record", encoded).commit()
                            clearFailures()
                            main.post {
                                unlocked = MediaRuntime.visible && revision == generation
                                result.success(null)
                                channel.invokeMethod("changed", null)
                            }
                        }
                        else -> main.post { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    main.post { result.error("pin", if (e is IllegalStateException) e.message else "PIN storage is unavailable. Restart the app or reset it through Android settings.", null) }
                }
            }
        }
    }
}
