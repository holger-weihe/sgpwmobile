package com.example.sgpwmobile

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.webkit.WebView

/**
 * ContentProvider that runs at app startup to initialize WebView SSL configuration
 */
class WebViewInitializationProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        // This runs very early in the app lifecycle
        try {
            // Enable insecure SSL connections for development
            WebViewSSLManager.enableAutoConfiguration()
            android.util.Log.d("WebViewInit", "WebView SSL configuration enabled")
        } catch (e: Exception) {
            android.util.Log.e("WebViewInit", "Failed to initialize WebView SSL config", e)
        }
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<String>?,
        selection: String?,
        selectionArgs: Array<String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<String>?
    ): Int = 0
}
