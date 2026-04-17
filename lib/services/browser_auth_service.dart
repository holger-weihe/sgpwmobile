import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'dart:convert';

/// Model to store captured browser authentication data
class BrowserAuthData {
  final String? token;
  final String? cookies;
  final String? oauthCode;
  final String? sessionId;
  final DateTime capturedAt;
  final String? method;

  BrowserAuthData({
    this.token,
    this.cookies,
    this.oauthCode,
    this.sessionId,
    this.method,
  }) : capturedAt = DateTime.now();

  Map<String, dynamic> toJson() => {
    'token': token,
    'cookies': cookies,
    'oauthCode': oauthCode,
    'sessionId': sessionId,
    'capturedAt': capturedAt.toIso8601String(),
    'method': method,
  };

  factory BrowserAuthData.fromJson(Map<String, dynamic> json) => BrowserAuthData(
    token: json['token'],
    cookies: json['cookies'],
    oauthCode: json['oauthCode'],
    sessionId: json['sessionId'],
    method: json['method'],
  );

  bool get isValid => token != null || cookies != null || oauthCode != null;
  bool get isExpired => DateTime.now().difference(capturedAt).inHours > 1;
}

/// Service to capture authentication data from browser login in WebView
class BrowserAuthService {
  static const _storageKey = 'browser_auth_data';
  static const _tokenKey = 'browser_auth_token';
  static const _cookieKey = 'browser_auth_cookies';
  static const _methodKey = 'browser_auth_method';
  
  final FlutterSecureStorage _secureStorage;
  
  BrowserAuthService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  /// Setup WebView to capture authentication data (OAuth redirects, etc.)
  void setupWebViewCapture(
    WebViewController controller, {
    required Function(BrowserAuthData) onAuthCaptured,
    required Function(String) onDebugLog,
  }) {
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (String url) async {
          onDebugLog('[BrowserAuth] Page loaded: $url');
          
          // Check if login was successful
          if (_isLoginSuccessPage(url)) {
            onDebugLog('[BrowserAuth] ✓ Login success page detected');
            onDebugLog('[BrowserAuth] ⏳ Waiting for OAuth callback or token extraction...');
          }
        },
        onNavigationRequest: (NavigationRequest request) {
          return _onNavigationRequest(request, onAuthCaptured, onDebugLog);
        },
      ),
    );
  }

  /// Handle navigation requests - check for OAuth redirects
  NavigationDecision _onNavigationRequest(
    NavigationRequest request,
    Function(BrowserAuthData) onAuthCaptured,
    Function(String) onDebugLog,
  ) {
    try {
      final uri = Uri.parse(request.url);
      
      // Check for OAuth2 callback pattern
      if (_isOAuthCallback(uri)) {
        onDebugLog('[BrowserAuth] 🔄 OAuth callback detected: ${request.url}');
        
        final code = uri.queryParameters['code'];
        final token = uri.queryParameters['token'];
        final state = uri.queryParameters['state'];
        
        if (code != null || token != null) {
          final authData = BrowserAuthData(
            oauthCode: code,
            token: token,
            sessionId: state,
            method: 'oauth2_redirect_${code != null ? 'code' : 'token'}',
          );
          
          onDebugLog('[BrowserAuth] ✅ OAuth captured: code=${code?.substring(0, 10)}...');
          saveAuthData(authData);
          onAuthCaptured(authData);
          return NavigationDecision.prevent;
        }
      }
      
      return NavigationDecision.navigate;
    } catch (e) {
      onDebugLog('[BrowserAuth] Navigation error: $e');
      return NavigationDecision.navigate;
    }
  }

  /// Check if URL indicates successful login
  bool _isLoginSuccessPage(String url) {
    final indicators = [
      'dashboard',
      'authenticated',
      'success',
      'home',
      'account',
      'welcome',
      '/rsts/ui',
      'safeguard',
    ];
    
    return indicators.any((keyword) => url.toLowerCase().contains(keyword));
  }

  /// Check if URL is an OAuth2 callback
  bool _isOAuthCallback(Uri uri) {
    return uri.path.contains('callback') ||
           uri.path.contains('oauth') ||
           uri.path.contains('authorize') ||
           uri.queryParameters.containsKey('code') ||
           uri.queryParameters.containsKey('token');
  }

  /// Save authentication data securely
  Future<void> saveAuthData(BrowserAuthData authData) async {
    try {
      await _secureStorage.write(
        key: _storageKey,
        value: jsonEncode(authData.toJson()),
      );
      
      if (authData.token != null) {
        await _secureStorage.write(key: _tokenKey, value: authData.token!);
      }
      if (authData.cookies != null) {
        await _secureStorage.write(key: _cookieKey, value: authData.cookies!);
      }
      if (authData.method != null) {
        await _secureStorage.write(key: _methodKey, value: authData.method!);
      }
    } catch (e) {
      print('[BrowserAuth] Save error: $e');
    }
  }

  /// Retrieve saved authentication data
  Future<BrowserAuthData?> getSavedAuthData() async {
    try {
      final stored = await _secureStorage.read(key: _storageKey);
      if (stored != null) {
        final data = BrowserAuthData.fromJson(jsonDecode(stored));
        
        // Check if expired (older than 1 hour)
        if (!data.isExpired) {
          return data;
        } else {
          print('[BrowserAuth] Saved auth data expired');
          await clearAuthData();
          return null;
        }
      }
    } catch (e) {
      print('[BrowserAuth] Read error: $e');
    }
    return null;
  }

  /// Clear saved authentication data
  Future<void> clearAuthData() async {
    try {
      await _secureStorage.delete(key: _storageKey);
      await _secureStorage.delete(key: _tokenKey);
      await _secureStorage.delete(key: _cookieKey);
      await _secureStorage.delete(key: _methodKey);
    } catch (e) {
      print('[BrowserAuth] Clear error: $e');
    }
  }
}
