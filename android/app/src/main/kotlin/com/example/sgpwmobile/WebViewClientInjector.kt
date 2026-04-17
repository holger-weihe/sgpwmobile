package com.example.sgpwmobile

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView

/**
 * Utility to apply SSL configuration to WebView instances in the view hierarchy
 */
object WebViewClientInjector {
    fun injectSSLClientIntoWebViews(activity: Activity) {
        try {
            val rootView = activity.window.decorView.findViewById<ViewGroup>(android.R.id.content)
            injectIntoViewHierarchy(rootView)
        } catch (e: Exception) {
            android.util.Log.e("WebViewClientInjector", "Error injecting SSL client", e)
        }
    }

    private fun injectIntoViewHierarchy(view: View) {
        if (view is WebView) {
            WebViewSSLManager.configureWebView(view)
            android.util.Log.d("WebViewClientInjector", "Injected SSL client into WebView")
        }

        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                injectIntoViewHierarchy(view.getChildAt(i))
            }
        }
    }
}
