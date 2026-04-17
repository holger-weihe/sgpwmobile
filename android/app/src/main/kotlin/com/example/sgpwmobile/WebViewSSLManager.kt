package com.example.sgpwmobile

import android.webkit.WebView
import android.net.http.SslError
import android.webkit.SslErrorHandler

/**
 * Singleton to manage WebView SSL configuration globally
 */
object WebViewSSLManager {
    private val insecureClient = InsecureWebViewClient()
    private val managedWebViews = mutableSetOf<WebView>()
    private var autoConfigureEnabled = false

    fun enableAutoConfiguration() {
        autoConfigureEnabled = true
    }

    fun configureWebView(webView: WebView) {
        webView.webViewClient = insecureClient
        managedWebViews.add(webView)
    }

    fun isAutoConfigureEnabled(): Boolean = autoConfigureEnabled

    class InsecureWebViewClient : android.webkit.WebViewClient() {
        override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) {
            android.util.Log.w("WebViewSSL", "SSL Error: ${error?.primaryError} - ${error?.url}")
            handler?.proceed()
        }

        override fun onReceivedError(view: WebView?, request: android.webkit.WebResourceRequest?, error: android.webkit.WebResourceError?) {
            super.onReceivedError(view, request, error)
            android.util.Log.w("WebViewSSL", "Error: ${error?.description}")
        }
    }
}
