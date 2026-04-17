package com.example.sgpwmobile

import android.net.http.SslError
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebResourceError
import android.webkit.WebView
import android.webkit.WebViewClient

class InsecureWebViewClient : WebViewClient() {
    
    override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) {
        // Ignore all SSL errors - proceed with loading
        handler?.proceed()
    }
    
    override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
        super.onReceivedError(view, request, error)
        // Log but don't block on errors
        android.util.Log.w("WebViewClient", "WebView error: ${error?.description}")
    }
}
