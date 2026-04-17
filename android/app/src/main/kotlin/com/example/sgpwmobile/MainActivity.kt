package com.example.sgpwmobile

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import android.webkit.WebView

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.example.sgpwmobile/biometric"
    private lateinit var executor: Executor
    private lateinit var biometricPrompt: BiometricPrompt
    private lateinit var promptInfo: BiometricPrompt.PromptInfo

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Initialize TLS channel handler for native mutual TLS support
        val tlsHandler = TlsChannelHandler(this)
        tlsHandler.setupChannel(flutterEngine)
        
        // Setup biometric method channel
        setupBiometricChannel(flutterEngine)
        
        // Setup WebView configuration channel
        setupWebViewChannel(flutterEngine)
    }
    
    private fun setupWebViewChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.sgpwmobile/webview")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "configureSSL" -> {
                        try {
                            WebViewSSLManager.enableAutoConfiguration()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERROR", "Failed to configure SSL: ${e.message}", null)
                        }
                    }
                    "injectSSLClient" -> {
                        try {
                            WebViewClientInjector.injectSSLClientIntoWebViews(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERROR", "Failed to inject SSL client: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        
        // Enable SSL configuration on startup
        WebViewSSLManager.enableAutoConfiguration()
    }

    private fun setupBiometricChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "authenticate") {
                    val reason = call.argument<String>("reason") ?: "Authenticate"
                    authenticateWithBiometric(reason, result)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun authenticateWithBiometric(reason: String, result: MethodChannel.Result) {
        executor = ContextCompat.getMainExecutor(this)
        
        // Create biometric prompt callback
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                super.onAuthenticationError(errorCode, errString)
                result.success(false)
            }

            override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                super.onAuthenticationSucceeded(authResult)
                result.success(true)
            }

            override fun onAuthenticationFailed() {
                super.onAuthenticationFailed()
                result.success(false)
            }
        }

        biometricPrompt = BiometricPrompt(this, executor, callback)
        
        promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Biometric Authentication")
            .setSubtitle(reason)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.BIOMETRIC_WEAK)
            .setNegativeButtonText("Cancel")
            .build()

        biometricPrompt.authenticate(promptInfo)
    }
}
