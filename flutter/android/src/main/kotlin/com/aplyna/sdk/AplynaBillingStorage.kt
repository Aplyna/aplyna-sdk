package com.aplyna.sdk

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal fun billingHash(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
internal interface BillingStorage : AutoCloseable { fun read(): JSONObject?; fun write(value: JSONObject); override fun close() {} }

/** Device-bound credentials and purchase tokens are excluded from Android backup. */
internal class AndroidBillingStorage(context: Context, scope: String) : BillingStorage {
    private val scopeHash = billingHash(scope)
    private val alias = "com.aplyna.billing.$scopeHash"
    private val file = AtomicFile(File(context.noBackupFilesDir, "aplyna-billing/$scopeHash"))
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private var leaseChannel: java.nio.channels.FileChannel? = null
    private var lease: java.nio.channels.FileLock? = null
    private var closed = false
    private fun acquire() {
        if (closed) throw AplynaBillingException("APLYNA_BILLING_CLOSED", "The billing identity store is closed.")
        if (lease != null) return
        file.baseFile.parentFile!!.mkdirs()
        val channel = java.io.RandomAccessFile(File(file.baseFile.path + ".lock"), "rw").channel
        try {
            val acquired = channel.tryLock() ?: throw IllegalStateException("Identity already in use")
            leaseChannel = channel; lease = acquired
        } catch (e: Exception) { channel.close(); throw AplynaBillingException("APLYNA_BILLING_IDENTITY_IN_USE", "Use one billing client per app scope; another client already owns this identity.", e) }
    }
    private fun key(create: Boolean): SecretKey {
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) throw AplynaBillingException("APLYNA_BILLING_IDENTITY", "The device billing identity cannot be decrypted.")
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    @Synchronized override fun read(): JSONObject? {
        acquire()
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        try {
            val bytes = file.openRead().use { input -> require(input.channel.size() <= 1_048_576); input.readBytes() }
            require(bytes.size > 29 && bytes[0] == 1.toByte())
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
            cipher.updateAAD(scopeHash.toByteArray(Charsets.UTF_8))
            return JSONObject(String(cipher.doFinal(bytes.copyOfRange(13, bytes.size)), Charsets.UTF_8))
        } catch (e: Exception) { throw AplynaBillingException("APLYNA_BILLING_IDENTITY", "Stored billing identity is unavailable; it has not been replaced.", e) }
    }
    @Synchronized override fun write(value: JSONObject) {
        acquire()
        val plain = value.toString().toByteArray(Charsets.UTF_8)
        require(plain.size <= 1_048_500)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true)); cipher.updateAAD(scopeHash.toByteArray(Charsets.UTF_8))
        val encrypted = byteArrayOf(1) + cipher.iv + cipher.doFinal(plain)
        file.baseFile.parentFile!!.mkdirs()
        val stream = file.startWrite()
        try { stream.write(encrypted); file.finishWrite(stream) }
        catch (e: Exception) { file.failWrite(stream); throw AplynaBillingException("APLYNA_BILLING_IDENTITY", "Could not persist the billing identity.", e) }
    }
    @Synchronized override fun close() { closed = true; lease?.release(); lease = null; leaseChannel?.close(); leaseChannel = null }
}
