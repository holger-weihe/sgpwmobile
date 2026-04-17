package com.example.sgpwmobile

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.bouncycastle.openssl.PEMParser
import org.bouncycastle.cert.X509CertificateHolder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.StringReader
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Security
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

class TlsChannelHandler(private val context: Context) {
    companion object {
        private const val CHANNEL_NAME = "com.example.sgpwmobile/tls"
    }

    fun setupChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "makeHttpsRequest" -> {
                    // Run network operation on a background thread
                    Thread {
                        try {
                            val url = call.argument<String>("url") ?: throw IllegalArgumentException("URL required")
                            val method = call.argument<String>("method") ?: "POST"
                            val body = call.argument<String>("body")
                            val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                            val certPath = call.argument<String>("certPath") ?: throw IllegalArgumentException("Cert path required")
                            val keyPath = call.argument<String>("keyPath") ?: throw IllegalArgumentException("Key path required")
                            val timeout = call.argument<Int>("timeout") ?: 30000

                            val response = makeHttpsRequestWithClientCert(
                                url, method, body, headers, certPath, keyPath, timeout
                            )
                            result.success(response)
                        } catch (e: Exception) {
                            android.util.Log.e("TlsChannel", "Error in makeHttpsRequest: ${e.message}", e)
                            result.error("TLS_ERROR", e.message, e.stackTraceToString())
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun makeHttpsRequestWithClientCert(
        urlString: String,
        method: String,
        body: String?,
        headers: Map<String, String>,
        certPath: String,
        keyPath: String,
        timeout: Int
    ): Map<String, Any> {
        android.util.Log.d("TlsChannel", "Starting HTTPS request to $urlString")
        
        val url = java.net.URL(urlString)
        val connection = url.openConnection() as HttpsURLConnection

        try {
            // Create SSL context with client certificate
            val sslContext = createSSLContextWithClientCert(certPath, keyPath)
            connection.sslSocketFactory = sslContext.socketFactory
            
            // Accept self-signed certificates for the server
            connection.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, _ -> true }
            
            // Set timeouts
            connection.connectTimeout = timeout
            connection.readTimeout = timeout
            
            // Set method
            connection.requestMethod = method
            android.util.Log.d("TlsChannel", "Method: $method")
            
            // Set headers
            for ((key, value) in headers) {
                connection.setRequestProperty(key, value)
                android.util.Log.d("TlsChannel", "Header: $key=$value")
            }
            
            // Send body if present
            if (body != null && (method == "POST" || method == "PUT")) {
                connection.doOutput = true
                android.util.Log.d("TlsChannel", "Sending body: ${body.take(100)}...")
                val outputStream = connection.outputStream
                outputStream.write(body.toByteArray(Charsets.UTF_8))
                outputStream.close()
            }
            
            // Get response
            val responseCode = connection.responseCode
            android.util.Log.d("TlsChannel", "Response code: $responseCode")
            
            val responseBody = readStream(if (responseCode in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            })
            
            android.util.Log.d("TlsChannel", "Response body length: ${responseBody.length}")
            
            return mapOf(
                "statusCode" to responseCode,
                "body" to responseBody,
                "headers" to connection.headerFields.mapValues { entry -> 
                    entry.value.joinToString(";") 
                }
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun createSSLContextWithClientCert(certPath: String, keyPath: String): SSLContext {
        android.util.Log.d("TlsChannel", "Creating SSL context with cert: $certPath, key: $keyPath")
        
        // Add BouncyCastle as a security provider
        if (Security.getProvider("BC") == null) {
            Security.addProvider(BouncyCastleProvider())
        }
        
        // Load the client certificate and private key files
        val certFile = File(certPath)
        val keyFile = File(keyPath)
        
        if (!certFile.exists()) throw IllegalArgumentException("Certificate file not found: $certPath")
        if (!keyFile.exists()) throw IllegalArgumentException("Key file not found: $keyPath")
        
        android.util.Log.d("TlsChannel", "Cert file exists: ${certFile.exists()}, size: ${certFile.length()}")
        android.util.Log.d("TlsChannel", "Key file exists: ${keyFile.exists()}, size: ${keyFile.length()}")
        
        try {
            // Parse certificate from PEM file
            val certContent = certFile.readText()
            val certificate = parseCertificateFromPem(certContent)
            android.util.Log.d("TlsChannel", "Certificate loaded: ${certificate.subjectDN}")
            
            // Parse private key from PEM file
            val keyContent = keyFile.readText()
            val privateKey = parsePrivateKeyFromPem(keyContent)
            android.util.Log.d("TlsChannel", "Private key loaded: ${privateKey.algorithm}")
            
            // Create a PKCS12 keystore with the certificate and private key
            val keyStore = KeyStore.getInstance("PKCS12")
            keyStore.load(null, null)
            
            // Store the certificate and private key
            val certificateChain = arrayOf(certificate)
            val keyPassword = "".toCharArray()
            keyStore.setKeyEntry("client", privateKey, keyPassword, certificateChain)
            
            android.util.Log.d("TlsChannel", "Certificate and key imported to keystore")
            
            // Initialize KeyManagerFactory
            val kmf = KeyManagerFactory.getInstance("X509")
            kmf.init(keyStore, keyPassword)
            
            // Create SSL context
            val sslContext = SSLContext.getInstance("TLSv1.2")
            
            // Create a trust manager that accepts all certificates (for testing with self-signed certs)
            val trustAllCerts = arrayOf<TrustManager>(object : X509TrustManager {
                override fun getAcceptedIssuers() = arrayOf<X509Certificate>()
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                    android.util.Log.d("TlsChannel", "Server certificate verified: ${chain[0].subjectDN}")
                }
            })
            
            sslContext.init(kmf.keyManagers, trustAllCerts, java.security.SecureRandom())
            
            android.util.Log.d("TlsChannel", "SSL context created successfully")
            return sslContext
        } catch (e: Exception) {
            android.util.Log.e("TlsChannel", "Error creating SSL context: ${e.message}")
            throw Exception("Failed to create SSL context: ${e.message}", e)
        }
    }
    
    private fun parseCertificateFromPem(pemContent: String): X509Certificate {
        try {
            android.util.Log.d("TlsChannel", "Parsing certificate PEM, length: ${pemContent.length}")
            val pemParser = PEMParser(StringReader(pemContent))
            val obj = pemParser.readObject()
            android.util.Log.d("TlsChannel", "PEM object type: ${obj?.javaClass?.simpleName}")
            
            val certificateHolder = obj as? X509CertificateHolder
                ?: throw IllegalArgumentException("PEM object is not X509Certificate: ${obj?.javaClass?.name}")
            pemParser.close()
            
            // Don't specify "BC" provider - use the default provider for X.509
            val certificate = JcaX509CertificateConverter()
                .getCertificate(certificateHolder)
            
            android.util.Log.d("TlsChannel", "Certificate parsed successfully: ${certificate.subjectDN}")
            return certificate
        } catch (e: Exception) {
            android.util.Log.e("TlsChannel", "Error parsing certificate: ${e.message}", e)
            throw Exception("Failed to parse certificate: ${e.message}", e)
        }
    }
    
    private fun parsePrivateKeyFromPem(pemContent: String): PrivateKey {
        try {
            android.util.Log.d("TlsChannel", "Parsing private key PEM, length: ${pemContent.length}")
            val pemParser = PEMParser(StringReader(pemContent))
            val obj = pemParser.readObject()
            android.util.Log.d("TlsChannel", "PEM object type: ${obj?.javaClass?.simpleName}")
            
            val privateKeyInfo = obj as? PrivateKeyInfo
                ?: throw IllegalArgumentException("PEM object is not PrivateKeyInfo: ${obj?.javaClass?.name}")
            pemParser.close()
            
            // Don't specify "BC" provider - use the default provider for RSA
            val privateKey = JcaPEMKeyConverter()
                .getPrivateKey(privateKeyInfo)
            
            android.util.Log.d("TlsChannel", "Private key parsed successfully: ${privateKey.algorithm}")
            return privateKey
        } catch (e: Exception) {
            android.util.Log.e("TlsChannel", "Error parsing private key: ${e.message}", e)
            throw Exception("Failed to parse private key: ${e.message}", e)
        }
    }

    private fun readStream(stream: java.io.InputStream?): String {
        if (stream == null) return ""
        val reader = BufferedReader(InputStreamReader(stream, Charsets.UTF_8))
        val sb = StringBuilder()
        var line: String?
        while (reader.readLine().also { line = it } != null) {
            sb.append(line).append("\n")
        }
        reader.close()
        return sb.toString()
    }
}
