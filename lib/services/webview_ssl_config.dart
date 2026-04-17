import 'package:flutter/services.dart';

class WebViewSSLConfig {
  static const platform = MethodChannel('com.example.sgpwmobile/webview');

  static Future<void> ignoreSSLErrors() async {
    try {
      await platform.invokeMethod('configureSSL');
      print('WebView SSL verification disabled');
    } catch (e) {
      print('Error configuring WebView SSL: $e');
    }
  }
}
