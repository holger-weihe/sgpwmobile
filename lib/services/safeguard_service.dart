import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/auth_token.dart';
import '../models/api_request.dart';
import '../models/account_tree.dart';
import '../models/cached_password.dart';
import 'certificate_service.dart';
import 'database_service.dart';
import 'data_encryption_service.dart';
import 'browser_auth_service.dart';

class SafeguardService {
  final String serverAddress;
  final CertificateService certificateService;
  final DatabaseService? databaseService;
  final DataEncryptionService? dataEncryptionService;
  final String? username; // Current logged-in user
  
  static const platform = MethodChannel('com.example.sgpwmobile/tls');
  
  AuthToken? _currentToken;
  AuthToken? _passwordAuthToken;
  BrowserAuthData? _browserAuthData;
  late Dio _dio;
  String? _certPath;
  String? _keyPath;

  SafeguardService({
    required this.serverAddress,
    required this.certificateService,
    this.databaseService,
    this.dataEncryptionService,
    this.username,
  }) {
    _dio = _createDioClient();
  }

  /// Create Dio client that accepts self-signed certificates
  Dio _createDioClient() {
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 30);
    dio.options.receiveTimeout = const Duration(seconds: 30);
    
    // Accept self-signed certificates
    (dio.httpClientAdapter as dynamic).onHttpClientCreate = (HttpClient client) {
      client.badCertificateCallback = (X509Certificate cert, String host, int port) {
        print('[TLS] Accepting certificate for $host:$port');
        return true;
      };
      return client;
    };
    
    return dio;
  }

  /// Write certificate and key PEM strings to temporary files
  /// Combines certificate and key into a single file for some SSL implementations
  Future<Map<String, String>> _writeCertificatesToTempFiles(String certPem, String keyPem) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final certFile = File('${tempDir.path}/client_cert.pem');
      final keyFile = File('${tempDir.path}/client_key.pem');
      final combinedFile = File('${tempDir.path}/client_combined.pem');
      
      // Write separate files
      await certFile.writeAsString(certPem);
      await keyFile.writeAsString(keyPem);
      
      // Also write combined file (key + cert) - some SSL implementations prefer this
      final combined = '$keyPem\n$certPem';
      await combinedFile.writeAsString(combined);
      
      print('[TLS] Wrote certificate to: ${certFile.path}');
      print('[TLS] Wrote private key to: ${keyFile.path}');
      print('[TLS] Wrote combined cert+key to: ${combinedFile.path}');
      
      return {
        'certPath': certFile.path,
        'keyPath': keyFile.path,
        'combinedPath': combinedFile.path,
      };
    } catch (e) {
      print('[TLS] Error writing temporary certificate files: $e');
      rethrow;
    }
  }

  /// Create Dio client with client certificate for mutual TLS
  Future<Dio> _createDioClientWithClientCert(String certPath, String keyPath) async {
    try {
      print('[TLS] Configuring Dio client with client certificate via SecurityContext...');
      
      // Try using combined file if available (more compatible with some SSL implementations)
      final tempDir = await getTemporaryDirectory();
      final combinedPath = '${tempDir.path}/client_combined.pem';
      
      // Create a security context and load certificate and key into it
      final context = SecurityContext.defaultContext;
      try {
        // Try loading combined file first
        print('[TLS] Attempting to load combined certificate file: $combinedPath');
        context.useCertificateChain(combinedPath);
        context.usePrivateKey(combinedPath);
        print('[TLS] Successfully loaded combined certificate and key');
      } catch (e) {
        print('[TLS] Combined file loading failed, trying separate files: $e');
        // Fall back to separate cert and key
        context.useCertificateChain(certPath);
        context.usePrivateKey(keyPath);
        print('[TLS] Successfully loaded separate certificate and key files');
      }
      
      // Create HttpClient with the security context that has client cert
      final HttpClient httpClient = HttpClient(context: context);
      httpClient.badCertificateCallback = (X509Certificate cert, String host, int port) {
        print('[TLS] Bypassing certificate verification for $host:$port');
        return true;
      };
      httpClient.connectionTimeout = const Duration(seconds: 30);
      
      // Create Dio with custom HttpClientAdapter using the configured client
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 30);
      dio.options.receiveTimeout = const Duration(seconds: 30);
      
      // Apply the HttpClient with client certificate to Dio adapter
      (dio.httpClientAdapter as dynamic).onHttpClientCreate = (HttpClient _) {
        print('[TLS] Using HttpClient with client certificate for this request');
        return httpClient;
      };
      
      print('[TLS] Dio client configured for mutual TLS');
      return dio;
    } catch (e) {
      print('[TLS] Error creating Dio client with cert: $e');
      print('[TLS] Falling back to non-mutual TLS client');
      return _createDioClient();
    }
  }

  /// Get the full server URL
  String _getServerUrl(String path) {
    String base = serverAddress;
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'https://$base';
    }
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return '$base$path';
  }

  /// Generate PKCE code verifier (43-128 characters of unreserved characters)
  String _generateCodeVerifier() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = math.Random.secure();
    return List.generate(128, (index) => chars[random.nextInt(chars.length)]).join();
  }

  /// Generate PKCE code challenge from verifier using SHA256
  String _generateCodeChallenge(String codeVerifier) {
    final bytes = utf8.encode(codeVerifier);
    final digest = sha256.convert(bytes);
    // Base64 URL encode without padding
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Authenticate using OAuth2 with PKCE (simplified for cert-based auth)
  /// Since certificate proves identity, skip authorization code and request token directly
  Future<AuthToken> authenticateWithPkce() async {
    try {
      print('[AUTH_PKCE] Starting OAuth2 PKCE authentication with cert-based client...');
      
      // Generate PKCE parameters
      final codeVerifier = _generateCodeVerifier();
      final codeChallenge = _generateCodeChallenge(codeVerifier);
      print('[AUTH_PKCE] Generated code verifier (length: ${codeVerifier.length}) and challenge');
      
      // With certificate-based auth, request token directly without authorization code step
      final apiToken = await _requestOAuth2Token(codeVerifier, codeChallenge);
      print('[AUTH_PKCE] Got API token, expires at: ${apiToken.expiresAt}');
      
      _currentToken = apiToken;
      return apiToken;
    } catch (e) {
      print('[AUTH_PKCE] PKCE authentication failed: $e');
      throw Exception('PKCE authentication failed: $e');
    }
  }

  /// Request OAuth2 token directly using PKCE (cert auth proves identity, no auth code needed)
  Future<AuthToken> _requestOAuth2Token(String codeVerifier, String codeChallenge) async {
    try {
      // Try multiple possible OAuth2 token endpoints
      final possibleUrls = [
        _getServerUrl('/oauth2/token'),
        _getServerUrl('/RSTS/oauth2/token'),
      ];

      for (final url in possibleUrls) {
        try {
          print('[AUTH_PKCE] Attempting token request to: $url');
          final token = await _tryOAuth2TokenEndpoint(url, codeVerifier, codeChallenge);
          print('[AUTH_PKCE] Successfully obtained token from $url');
          return token;
        } catch (e) {
          print('[AUTH_PKCE] Token endpoint $url failed: $e');
          // Continue to next URL
        }
      }
      
      throw Exception('All OAuth2 token endpoints failed');
    } catch (e) {
      print('[AUTH_PKCE] Error requesting OAuth2 token: $e');
      rethrow;
    }
  }

  /// Try a specific OAuth2 token endpoint with PKCE
  Future<AuthToken> _tryOAuth2TokenEndpoint(
    String url,
    String codeVerifier,
    String codeChallenge,
  ) async {
    final headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
    };

    // With certificate-based auth, use client_credentials or implicit flow with PKCE
    final body = {
      'grant_type': 'client_credentials',  // Or 'implicit' with code_challenge
      'code_verifier': codeVerifier,
      'code_challenge': codeChallenge,
      'client_id': 'SPPMobileApp',
      'scope': 'openid profile offline_access',
    };

    final formBody = body.entries
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');

    final response = await _makeNativeHttpsRequest(
      url: url,
      method: 'POST',
      headers: headers,
      body: formBody,
    );

    if (response['statusCode'] == 200) {
      final data = jsonDecode(response['body'] as String) as Map<String, dynamic>;
      print('[AUTH_PKCE] Token response received (contains: ${data.keys.join(', ')})');
      return AuthToken.fromJson(data);
    } else {
      throw Exception(
        'Token request failed (${response['statusCode']}): ${response['body']}',
      );
    }
  }

  /// Authenticate using username and password (Resource Owner Password Credentials)
  /// Three-step flow: RSTS token -> API token -> Verification
  /// Mirrors Java SDK pattern: Safeguard.connect(appliance, provider, username, password, null, true)
  /// Uses RstsProviderId from provider lookup for correct scope construction
  Future<AuthToken> authenticateWithPassword({
    required String providerName,
    required String rstsProviderId,
    required String username,
    required String password,
  }) async {
    try {
      print('[AUTH_PASSWORD] Starting password authentication for user: $username on provider: $providerName ($rstsProviderId)');
      
      // Step 1: Get RSTS token using password grant
      final rstsToken = await _requestRstsTokenWithPassword(rstsProviderId, username, password);
      print('[AUTH_PASSWORD] ✓ Got RSTS token (${rstsToken.length} chars)');
      
      // Step 2: Exchange RSTS token for Safeguard API token
      final apiToken = await _exchangeRstsTokenForApiToken(rstsToken);
      print('[AUTH_PASSWORD] ✓ Got API token, expires at: ${apiToken.expiresAt}');
      
      // Step 3: Verify token works
      await _verifyApiTokenWorks(apiToken.userToken);
      print('[AUTH_PASSWORD] ✓ Token verified successfully');
      
      _currentToken = apiToken;
      return apiToken;
    } catch (e) {
      print('[AUTH_PASSWORD] ✗ Password authentication failed: $e');
      throw Exception('Password authentication failed: $e');
    }
  }

  /// Request RSTS token using Resource Owner Password Credentials flow
  /// Uses Dio with relaxed certificate validation for self-signed certs
  Future<String> _requestRstsTokenWithPassword(
    String rstsProviderId,
    String username,
    String password,
  ) async {
    try {
      final rstsUrl = _getServerUrl('/RSTS/oauth2/token');
      print('[RSTS] Requesting token from: $rstsUrl');
      print('[RSTS] RstsProviderId: $rstsProviderId, Username: $username');
      
      // Create HTTP client that accepts self-signed certificates
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = (cert, host, port) => true;
      
      // Create Dio instance with relaxed SSL validation
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (status) => status != null,
      ));
      
      dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => httpClient);

      final body = {
        'grant_type': 'password',
        'username': username,
        'password': password,
        'scope': 'rsts:sts:primaryproviderid:$rstsProviderId',
      };

      final formBody = body.entries
          .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');

      print('[RSTS] Sending password grant request...');
      final response = await dio.post(
        rstsUrl,
        data: formBody,
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          headers: {
            'Accept': 'application/json',
            'User-Agent': 'SGPWMobile/1.0',
          },
        ),
      );

      print('[RSTS] Response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final token = data['access_token'] as String?;
        if (token != null && token.isNotEmpty) {
          print('[RSTS] ✓ Token obtained (${token.length} chars)');
          return token;
        }
        throw Exception('Response does not contain access_token');
      } else if (response.statusCode == 400) {
        final errorBody = response.data.toString();
        print('[RSTS] ✗ 400 Bad Request: $errorBody');
        if (errorBody.contains('invalid_grant')) {
          throw Exception(
            'Invalid credentials or Resource Owner Grant is disabled on the appliance. '
            'Please verify credentials or contact your Safeguard administrator.',
          );
        }
        throw Exception('Invalid request: $errorBody');
      } else {
        throw Exception(
          'RSTS token request failed (${response.statusCode}): ${response.data}',
        );
      }
    } on DioException catch (e) {
      print('[RSTS] ✗ DioException: $e');
      if (e.response?.statusCode == 400) {
        final errorBody = e.response?.data.toString() ?? '';
        if (errorBody.contains('invalid_grant')) {
          throw Exception(
            'Invalid credentials or Resource Owner Grant is disabled on the appliance. '
            'Please verify credentials or contact your Safeguard administrator.',
          );
        }
      }
      rethrow;
    } catch (e) {
      print('[RSTS] ✗ Error: $e');
      rethrow;
    }
  }

  /// Set browser authentication data captured from WebView
  void setBrowserAuthData(BrowserAuthData? authData) {
    _browserAuthData = authData;
    print('[AUTH] Browser auth data set: ${authData?.method}');
  }

  /// Set API token from password authentication for use in API requests
  /// This allows password-authenticated users to make API calls
  void setPasswordAuthToken(AuthToken? token) {
    _passwordAuthToken = token;
    if (token != null) {
      print('[AUTH] Password auth token set (expires: ${token.expiresAt})');
    } else {
      print('[AUTH] Password auth token cleared');
    }
  }

  /// Try to authenticate using browser-captured credentials first
  /// Falls back to certificate-based PKCE if browser auth fails
  Future<AuthToken?> authenticateWithBrowserOrPkce() async {
    try {
      print('[AUTH] Starting hybrid authentication (browser -> PKCE fallback)');
      
      // First, try using saved browser authentication
      if (_browserAuthData != null && _browserAuthData!.isValid && !_browserAuthData!.isExpired) {
        print('[AUTH] Using cached browser auth: ${_browserAuthData!.method}');
        final token = await _authenticateWithBrowserData(_browserAuthData!);
        if (token != null) {
          _currentToken = token;
          return token;
        }
      }
      
      // Check for recently saved browser auth in secure storage
      final browserAuthService = BrowserAuthService();
      final savedAuth = await browserAuthService.getSavedAuthData();
      if (savedAuth != null && savedAuth.isValid && !savedAuth.isExpired) {
        print('[AUTH] Using saved browser auth: ${savedAuth.method}');
        _browserAuthData = savedAuth;
        final token = await _authenticateWithBrowserData(savedAuth);
        if (token != null) {
          _currentToken = token;
          return token;
        }
      }
      
      // Fall back to PKCE with certificates
      print('[AUTH] Browser auth failed, falling back to PKCE');
      final token = await authenticateWithPkce();
      return token;
    } catch (e) {
      print('[AUTH] Hybrid authentication failed: $e');
      return null;
    }
  }

  /// Authenticate using captured browser credentials
  Future<AuthToken?> _authenticateWithBrowserData(BrowserAuthData browserAuth) async {
    try {
      print('[AUTH_BROWSER] Attempting authentication with ${browserAuth.method}');
      
      // **NEW PATH**: rSTS token from WebView browser auth
      if (browserAuth.method == 'webview_rsts_token' && browserAuth.token != null && browserAuth.token!.isNotEmpty) {
        print('[AUTH_BROWSER] 🔐 Got rSTS token from browser authentication (${browserAuth.token!.length} chars)');
        print('[AUTH_BROWSER] Exchanging rSTS token for SPP API token...');
        try {
          final token = await _exchangeRstsTokenForApiToken(browserAuth.token!);
          print('[AUTH_BROWSER] ✅ Successfully exchanged rSTS token for API token');
          return token;
        } catch (e) {
          print('[AUTH_BROWSER] ❌ Failed to exchange rSTS token: $e');
          print('[AUTH_BROWSER] Falling back to certificate authentication...');
          return null; // Fall back to certificates
        }
      }
      
      // **EXISTING PATH**: OAuth token captured directly (if any)
      if (browserAuth.token != null && browserAuth.token!.isNotEmpty && browserAuth.method != 'webview_session') {
        print('[AUTH_BROWSER] OAuth token captured (${browserAuth.token!.length} chars), validating token...');
        final token = await _validateBrowserToken(browserAuth.token!);
        if (token != null) {
          print('[AUTH_BROWSER] ✓ Token validation successful');
          return token;
        }
        print('[AUTH_BROWSER] Token validation failed');
      }
      
      // **FALLBACK**: WebView session only (without rSTS token)
      if (browserAuth.method == 'webview_session') {
        print('[AUTH_BROWSER] ⚠️ WebView session detected (no OAuth token available)');
        print('[AUTH_BROWSER] ℹ️ WebView cookies are isolated on Android and cannot be used by HTTP client');
        print('[AUTH_BROWSER] ℹ️ Certificate-based authentication is required');
        return null;
      }
      
      // **FALLBACK**: OAuth code exchange (if captured)
      if (browserAuth.oauthCode != null && browserAuth.oauthCode!.isNotEmpty) {
        print('[AUTH_BROWSER] Exchanging OAuth code...');
        final token = await _exchangeOAuthCode(browserAuth.oauthCode!, browserAuth.sessionId);
        if (token != null) {
          print('[AUTH_BROWSER] ✓ OAuth exchange successful');
          return token;
        }
      }
      
      // **FALLBACK**: Try using cookies/session
      if (browserAuth.cookies != null && browserAuth.cookies!.isNotEmpty) {
        print('[AUTH_BROWSER] Attempting session authentication with extracted cookies...');
        final token = await _authenticateWithCookies(browserAuth.cookies!);
        if (token != null) {
          print('[AUTH_BROWSER] ✓ Session authentication successful');
          return token;
        }
      }
      
      print('[AUTH_BROWSER] ✗ Browser authentication not available - use certificates instead');
      return null;
    } catch (e) {
      print('[AUTH_BROWSER] Error: $e');
      return null;
    }
  }

  /// Try authenticating using WebView session (system cookies or extracted cookies)
  Future<AuthToken?> _tryWebViewSessionAuth() async {
    try {
      print('[AUTH_BROWSER] Making request relying on WebView session...');
      
      // If we have extracted cookies, use them explicitly
      print('[AUTH_BROWSER] Checking for extracted cookies: ${_browserAuthData?.cookies}');
      if (_browserAuthData?.cookies != null && _browserAuthData!.cookies!.isNotEmpty && _browserAuthData!.cookies != 'webview-session-authenticated') {
        final cookieLength = _browserAuthData!.cookies!.length;
        print('[AUTH_BROWSER] Found extracted cookies: $cookieLength bytes');
        
        // Check if cookies are meaningful (more than just whitespace)
        if (cookieLength > 5) {
          print('[AUTH_BROWSER] Using explicit cookies from WebView extraction');
          final token = await _authenticateWithCookies(_browserAuthData!.cookies!);
          if (token != null) {
            print('[AUTH_BROWSER] ✓ Authentication succeeded with extracted cookies');
            return token;
          }
          print('[AUTH_BROWSER] ✗ Authentication failed even with extracted cookies');
        } else {
          print('[AUTH_BROWSER] ⚠️ Extracted cookies too small ($cookieLength bytes) - likely HttpOnly, cannot send via Cookie header');
          print('[AUTH_BROWSER] ℹ️ ANDROID LIMITATION: WebView session cookies isolated from system HTTP client');
        }
      } else {
        print('[AUTH_BROWSER] ⚠️ No meaningful cookies extracted (HttpOnly cookies not accessible to JavaScript)');
      }
      
      // Otherwise, rely on system HTTP client having access to system cookies
      print('[AUTH_BROWSER] Making unauthenticated request to rely on system cookies...');
      
      // Try to get /Me endpoint without explicit credentials
      // Dio should automatically send cookies from system cookie jar
      final response = await _dio.get(
        _getServerUrl('/service/core/v4/Me'),
        options: Options(
          headers: {
            'Content-Type': 'application/json',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      
      print('[AUTH_BROWSER] /Me response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        // User is authenticated, try to exchange for a real token
        print('[AUTH_BROWSER] ✓ User is authenticated via system cookies');
        
        // Try to get a token via OAuth or other means
        // For now, return a marker that indicates successful auth
        // The actual token will be obtained when needed
        try {
          // Try to call the OAuth endpoint or token endpoint with the session
          // For Safeguard, we might need to call /oauth2/token or /api/authenticate
          final tokenResponse = await _dio.post(
            _getServerUrl('/oauth2/token'),
            data: {
              'grant_type': 'client_credentials',
              'client_id': 'SPPMobileApp',
            },
            options: Options(
              validateStatus: (status) => status != null && status < 500,
            ),
          );
          
          if (tokenResponse.statusCode == 200) {
            print('[AUTH_BROWSER] ✓ Token obtained from OAuth endpoint');
            final tokenData = tokenResponse.data as Map<dynamic, dynamic>;
            return AuthToken.fromJson(Map<String, dynamic>.from(tokenData));
          }
        } catch (e) {
          print('[AUTH_BROWSER] Could not get token from OAuth: $e');
        }
        
        // If OAuth failed but /Me worked, that means session is valid
        // Return a marker token
        print('[AUTH_BROWSER] Session valid but no token obtained, creating marker token');
        return AuthToken(
          userToken: 'webview-session-authenticated',
          status: 'Success',
          webClientInactivityTimeout: 2880,
          desktopClientInactivityTimeout: 1440,
          issuedAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 1)),
        );
      } else if (response.statusCode == 401) {
        print('[AUTH_BROWSER] 401 Unauthorized - WebView session not valid or cookies not transmitted');
        print('[AUTH_BROWSER] ⚠️ IMPORTANT: System HTTP client does not have access to WebView cookies');
        print('[AUTH_BROWSER] This is expected on Android - WebView has isolated cookie storage');
        return null;
      } else {
        print('[AUTH_BROWSER] /Me returned ${response.statusCode}: ${response.statusMessage}');
        print('[AUTH_BROWSER] Response: ${response.data}');
        return null;
      }
    } catch (e) {
      print('[AUTH_BROWSER] WebView session auth error: $e');
      return null;
    }
  }


  /// Validate a token with the Safeguard API
  Future<AuthToken?> _validateBrowserToken(String token) async {
    try {
      print('[AUTH_BROWSER] Validating OAuth token (${token.length} chars)...');
      
      // First, treat the JWT token as the auth token
      // Create a temporary AuthToken from the raw JWT
      try {
        // Try to use the token directly by calling /Me with it
        final headers = {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        };
        
        final response = await _dio.get(
          _getServerUrl('/service/core/v4/Me'),
          options: Options(
            headers: headers,
            validateStatus: (status) => status != null && status < 500,
          ),
        );
        
        if (response.statusCode == 200) {
          print('[AUTH_BROWSER] ✓ Token is valid - /Me endpoint authenticated successfully');
          // Token works! Create an AuthToken from it
          // The JWT itself IS the token we need
          return AuthToken(
            userToken: token,
            status: 'Success',
            webClientInactivityTimeout: 2880,
            desktopClientInactivityTimeout: 1440,
            issuedAt: DateTime.now(),
            expiresAt: DateTime.now().add(Duration(hours: 24)),
          );
        } else if (response.statusCode == 401) {
          print('[AUTH_BROWSER] Token validation failed: 401 Unauthorized');
          return null;
        } else {
          print('[AUTH_BROWSER] Token validation error: ${response.statusCode} ${response.statusMessage}');
        }
      } catch (e) {
        print('[AUTH_BROWSER] Error validating token: $e');
      }
      
      return null;
    } catch (e) {
      print('[AUTH_BROWSER] Token validation error: $e');
      return null;
    }
  }

  /// Exchange OAuth authorization code for token
  Future<AuthToken?> _exchangeOAuthCode(String code, String? state) async {
    try {
      final body = {
        'grant_type': 'authorization_code',
        'code': code,
        'state': state,
        'client_id': 'SPPMobileApp',
        'redirect_uri': 'sgpwmobile://oauth/callback',
      };
      
      final response = await _dio.post(
        _getServerUrl('/oauth2/token'),
        data: body,
      );
      
      if (response.statusCode == 200) {
        return AuthToken.fromJson(response.data);
      }
    } catch (e) {
      print('[AUTH_BROWSER] OAuth exchange error: $e');
    }
    
    return null;
  }

  /// Authenticate using browser cookies/session
  Future<AuthToken?> _authenticateWithCookies(String cookies) async {
    try {
      final headers = {
        'Cookie': cookies,
        'Content-Type': 'application/json',
      };
      
      // Request token using session cookies
      final response = await _dio.post(
        _getServerUrl('/api/authenticate'),
        options: Options(headers: headers),
      );
      
      if (response.statusCode == 200) {
        return AuthToken.fromJson(response.data);
      }
    } catch (e) {
      print('[AUTH_BROWSER] Cookie authentication error: $e');
    }
    
    return null;
  }

  /// Make API request with browser auth credentials if available
  Future<Response<T>> _makeRequestWithBrowserAuth<T>(
    String method,
    String url,
    Options? options,
    dynamic data,
  ) async {
    final finalOptions = options ?? Options();
    
    // Add browser auth headers if available
    if (_browserAuthData != null) {
      if (_browserAuthData!.token != null) {
        finalOptions.headers?['Authorization'] = 'Bearer ${_browserAuthData!.token}';
      }
      if (_browserAuthData!.cookies != null) {
        finalOptions.headers?['Cookie'] = _browserAuthData!.cookies!;
      }
    }
    
    return _dio.request<T>(
      url,
      data: data,
      options: finalOptions,
    );
  }

  /// Authenticate using browser auth (primary) or certificate-based OAuth 2.0 (fallback)
  /// username: optional username parameter for loading per-user certificate
  Future<AuthToken> authenticate({String? usernameParam}) async {
    try {
      final authUsername = usernameParam ?? username;
      print('[AUTH] Starting authentication process for user: $authUsername');
      
      // PRIMARY: Try browser authentication first (from captured browser login)
      print('[AUTH] Checking for browser authentication data...');
      
      // Try using cached browser auth
      if (_browserAuthData != null && _browserAuthData!.isValid && !_browserAuthData!.isExpired) {
        print('[AUTH] Using cached browser auth: ${_browserAuthData!.method}');
        final token = await _authenticateWithBrowserData(_browserAuthData!);
        if (token != null) {
          _currentToken = token;
          print('[AUTH] ✓ Browser authentication successful');
          return token;
        }
      }
      
      // Try loading recently saved browser auth from secure storage
      final browserAuthService = BrowserAuthService();
      final savedAuth = await browserAuthService.getSavedAuthData();
      if (savedAuth != null && savedAuth.isValid && !savedAuth.isExpired) {
        print('[AUTH] Using saved browser auth: ${savedAuth.method}');
        _browserAuthData = savedAuth;
        final token = await _authenticateWithBrowserData(savedAuth);
        if (token != null) {
          _currentToken = token;
          print('[AUTH] ✓ Browser authentication successful');
          return token;
        }
      }
      
      print('[AUTH] Browser auth not available or failed, attempting certificate-based auth...');
      
      // FALLBACK: Use certificate-based authentication if available
      // Load certificate and key from storage (may be per-user or global)
      final cert = await certificateService.getCertificate(username: authUsername);
      final key = await certificateService.getPrivateKey(username: authUsername);
      print('[AUTH] Certificate loaded - Cert: ${cert != null}, Key: ${key != null}');
      
      if (cert == null || key == null) {
        throw Exception(
          'Authentication failed: Browser session could not be used with HTTP client (Android limitation). '
          'No certificate found for certificate-based authentication. '
          'Please go to Setup and either: 1) Re-login via browser and try again, '
          'or 2) Upload an X.509 certificate and private key for certificate-based authentication.'
        );
      }

      // Set up mutual TLS by writing certs to temp files
      print('[AUTH] Setting up mutual TLS with client certificate...');
      final paths = await _writeCertificatesToTempFiles(cert, key);
      _certPath = paths['certPath'];
      _keyPath = paths['keyPath'];
      print('[AUTH] Certificates ready for native TLS');
      
      // Try OAuth2 PKCE flow first
      try {
        print('[AUTH] Attempting OAuth2 PKCE authentication...');
        return await authenticateWithPkce();
      } catch (e) {
        print('[AUTH] PKCE auth failed, falling back to certificate-based auth: $e');
        // Fallback to certificate-based authentication
        // Step 1: Get rSTS token using certificate-based mutual TLS
        print('[AUTH] Requesting rSTS token from ${_getServerUrl('/RSTS/oauth2/token')}');
        final rStsToken = await _getRstsToken();
        print('[AUTH] Got rSTS token (length: ${rStsToken.length})');
        
        // Step 2: Exchange for SPP API token
        print('[AUTH] Exchanging rSTS token for API token...');
        final apiToken = await _exchangeRstsTokenForApiToken(rStsToken);
        print('[AUTH] Got API token, expires at: ${apiToken.expiresAt}');
        
        _currentToken = apiToken;
        return apiToken;
      }
    } catch (e) {
      print('[AUTH] Authentication failed: $e');
      throw Exception('Authentication failed: $e');
    }
  }

  /// Make HTTPS request using native Android TLS implementation for mutual TLS
  Future<Map<String, dynamic>> _makeNativeHttpsRequest({
    required String url,
    required String method,
    required Map<String, String> headers,
    String? body,
    int timeout = 30000,
  }) async {
    try {
      if (_certPath == null || _keyPath == null) {
        throw Exception('Certificate paths not set. Call authenticate first.');
      }

      print('[NATIVE_TLS] Calling native method channel for $method request to $url');

      final result = await platform.invokeMethod<Map<dynamic, dynamic>>(
        'makeHttpsRequest',
        {
          'url': url,
          'method': method,
          'body': body,
          'headers': headers,
          'certPath': _certPath,
          'keyPath': _keyPath,
          'timeout': timeout,
        },
      );

      if (result == null) {
        throw Exception('Native method returned null');
      }

      print('[NATIVE_TLS] Native request successful, status: ${result['statusCode']}');

      return {
        'statusCode': result['statusCode'] as int,
        'body': result['body'] as String,
        'headers': (result['headers'] as Map<dynamic, dynamic>?)?.cast<String, String>() ?? {},
      };
    } on PlatformException catch (e) {
      print('[NATIVE_TLS] Platform exception: ${e.code} - ${e.message}');
      throw Exception('Native TLS error: ${e.message}');
    } catch (e) {
      print('[NATIVE_TLS] Exception during native request: $e');
      throw Exception('Failed to make native HTTPS request: $e');
    }
  }

  /// Step 1: Get rSTS OAuth token using mutual TLS authentication
  /// Uses native Android TLS implementation for proper client certificate handling
  Future<String> _getRstsToken() async {
    final url = _getServerUrl('/RSTS/oauth2/token');
    
    // OAuth2 request body - certificate is presented via mutual TLS in handshake
    final body = {
      'grant_type': 'client_credentials',
      'scope': 'rsts:sts:primaryproviderid:certificate',
    };

    // Form-encode the body
    final formBody = body.entries
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');

    try {
      print('[AUTH] Sending rSTS token request via native Android TLS to: $url');
      
      final headers = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
      };

      // Use native implementation for mutual TLS
      final response = await _makeNativeHttpsRequest(
        url: url,
        method: 'POST',
        headers: headers,
        body: formBody,
      );

      print('[AUTH] rSTS response status: ${response['statusCode']}');
      final responseBody = response['body'] as String;
      print('[AUTH] rSTS response body: ${responseBody.substring(0, math.min(300, responseBody.length))}');

      if (response['statusCode'] == 200) {
        final data = jsonDecode(responseBody) as Map<String, dynamic>;
        final accessToken = data['access_token'] as String?;
        if (accessToken == null) {
          throw Exception('No access token in response');
        }
        print('[AUTH] Successfully got rSTS token');
        return accessToken;
      } else {
        throw Exception(
          'rSTS authentication failed (${response['statusCode']}): $responseBody',
        );
      }
    } catch (e) {
      print('[AUTH] Exception during rSTS request: $e');
      throw Exception('Failed to get rSTS token: $e');
    }
  }

  /// Step 2: Exchange rSTS token for SPP API token using Dio
  /// Uses /service/core/v4/Token/LoginResponse endpoint
  Future<AuthToken> _exchangeRstsTokenForApiToken(String rStsToken) async {
    try {
      final url = _getServerUrl('/service/core/v4/Token/LoginResponse');
      print('[API_TOKEN] Exchanging RSTS token at: $url');
      
      // Create HTTP client that accepts self-signed certificates
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = (cert, host, port) => true;
      
      // Create Dio instance with relaxed SSL validation
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (status) => status != null,
      ));
      
      dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => httpClient);
      
      final body = {'StsAccessToken': rStsToken};

      print('[API_TOKEN] Sending token exchange request...');
      final response = await dio.post(
        url,
        data: jsonEncode(body),
        options: Options(
          contentType: 'application/json',
          headers: {
            'Accept': 'application/json',
            'User-Agent': 'SGPWMobile/1.0',
          },
        ),
      );

      print('[API_TOKEN] Response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        print('[API_TOKEN] ✓ Exchanged successfully, token expires at: ${data['UserTokenExpirationDate']}');
        return AuthToken.fromJson(data);
      } else {
        throw Exception(
          'SPP API token exchange failed (${response.statusCode}): ${response.data}',
        );
      }
    } on DioException catch (e) {
      print('[API_TOKEN] ✗ DioException: $e');
      throw Exception('Failed to exchange for API token: $e');
    } catch (e) {
      print('[API_TOKEN] ✗ Error: $e');
      throw Exception('Failed to exchange for API token: $e');
    }
  }

  /// Step 3: Verify that the API token is valid
  /// Calls /service/core/v4/Me endpoint to verify token and get user info
  Future<void> _verifyApiTokenWorks(String apiToken) async {
    try {
      final url = _getServerUrl('/service/core/v4/Me');
      print('[VERIFY] Verifying API token at: $url');
      
      // Create HTTP client that accepts self-signed certificates
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = (cert, host, port) => true;
      
      // Create Dio instance with relaxed SSL validation
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (status) => status != null,
      ));
      
      dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => httpClient);
      
      print('[VERIFY] Making request with API token...');
      final response = await dio.get(
        url,
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $apiToken',
            'User-Agent': 'SGPWMobile/1.0',
          },
        ),
      );

      print('[VERIFY] Response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final displayName = data['DisplayName'] ?? 'Unknown';
        print('[VERIFY] ✓ Token verified! User: $displayName');
      } else {
        throw Exception(
          'Token verification failed (${response.statusCode}): ${response.data}',
        );
      }
    } on DioException catch (e) {
      print('[VERIFY] ✗ DioException: $e');
      throw Exception('Token verification failed: $e');
    } catch (e) {
      print('[VERIFY] ✗ Error: $e');
      throw Exception('Token verification failed: $e');
    }
  }

  /// Execute an API request to Safeguard
  /// Prefers password authentication token if available, falls back to certificate authentication
  Future<ApiResponse> executeApiRequest(ApiRequest request) async {
    // Determine which token to use: prefer password auth token if available
    final token = _passwordAuthToken ?? _currentToken;
    
    if (token == null) {
      throw Exception('Not authenticated. Please authenticate first with password or certificate authentication.');
    }

    if (token.isExpired) {
      throw Exception('Token expired. Please re-authenticate.');
    }

    try {
      final url = _getServerUrl(request.endpoint);
      final headers = {
        'Authorization': 'Bearer ${token.userToken}',
        'Accept': 'application/json',
      };

      // Add content type for methods that have a body
      if (request.method != HttpMethod.get && request.method != HttpMethod.delete) {
        headers['Content-Type'] = 'application/json';
      }

      String? body;
      if (request.body != null) {
        body = request.body is String ? request.body : jsonEncode(request.body);
      }

      // Use Dio for password auth (accepts self-signed), native HTTPS for certificate auth
      print('[API] Executing ${request.method.value.toUpperCase()} request to $url');
      final authType = _passwordAuthToken != null ? 'password auth' : 'certificate auth';
      print('[API] Using $authType token');
      print('[API] Authorization header: Bearer ${token.userToken.substring(0, math.min(50, token.userToken.length))}...');
      print('[API] Headers: $headers');
      
      final isPasswordAuth = _passwordAuthToken != null;
      
      if (isPasswordAuth) {
        // For password auth, use Dio with self-signed cert acceptance
        print('[API] Using Dio HTTP client for password auth token');
        
        final httpClient = HttpClient();
        httpClient.badCertificateCallback = (cert, host, port) => true;
        
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          validateStatus: (status) => status != null,
        ));
        
        dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => httpClient);
        
        late Response<String> response;
        
        if (request.method == HttpMethod.get) {
          response = await dio.get<String>(url, options: Options(headers: headers));
        } else if (request.method == HttpMethod.post) {
          response = await dio.post<String>(url, data: body, options: Options(headers: headers));
        } else if (request.method == HttpMethod.put) {
          response = await dio.put<String>(url, data: body, options: Options(headers: headers));
        } else if (request.method == HttpMethod.delete) {
          response = await dio.delete<String>(url, options: Options(headers: headers));
        } else {
          throw Exception('Unsupported HTTP method: ${request.method}');
        }
        
        print('[API] Response status: ${response.statusCode}');
        final responseBody = response.data ?? '';
        print('[API] Response body (first 200 chars): ${responseBody.substring(0, math.min(200, responseBody.length))}');
        
        final isSuccess = response.statusCode != null && response.statusCode! >= 200 && response.statusCode! < 300;
        
        return ApiResponse(
          statusCode: response.statusCode ?? 0,
          body: responseBody,
          isSuccess: isSuccess,
          errorMessage: isSuccess ? null : 'API Error: ${response.data}',
        );
      } else {
        // For certificate auth, use native HTTPS
        print('[API] Using native HTTPS for certificate auth token');
        
        final response = await _makeNativeHttpsRequest(
          url: url,
          method: request.method.value.toUpperCase(),
          headers: headers,
          body: body,
        );
        
        print('[API] Response status: ${response['statusCode']}');
        print('[API] Response body (first 200 chars): ${(response['body'] as String).substring(0, math.min(200, (response['body'] as String).length))}');

        final isSuccess = response['statusCode'] >= 200 && response['statusCode'] < 300;
        
        return ApiResponse(
          statusCode: response['statusCode'],
          body: response['body'],
          isSuccess: isSuccess,
          errorMessage: isSuccess ? null : 'API Error: ${response['body']}',
        );
      }
    } catch (e) {
      return ApiResponse(
        statusCode: 0,
        body: '',
        isSuccess: false,
        errorMessage: 'Error executing request: $e',
      );
    }
  }

  /// Debug: Check if certificate data is valid
  Future<void> debugCertificateStatus() async {
    try {
      final cert = await certificateService.getCertificate();
      final key = await certificateService.getPrivateKey();
      print('[DEBUG] Certificate loaded - Cert: ${cert != null}, Key: ${key != null}');
      if (cert != null) print('[DEBUG] Cert length: ${cert.length}');
      if (key != null) print('[DEBUG] Key length: ${key.length}');
    } catch (e) {
      print('[DEBUG] Error checking certificate: $e');
    }
  }

  /// Fetch folders from Safeguard API
  /// Returns map of folder ID to folder data
  Future<Map<String, dynamic>> getFolders(String endpoint) async {
    // Check both password auth token and certificate auth token
    final token = _passwordAuthToken ?? _currentToken;
    
    if (token == null) {
      throw Exception('Not authenticated. Please authenticate first.');
    }

    try {
      // Determine folders endpoint based on account endpoint
      String foldersEndpoint;
      if (endpoint.contains('EnterpriseAccounts')) {
        foldersEndpoint = '/service/core/v4/Me/EnterpriseFolders';
      } else {
        foldersEndpoint = '/service/core/v4/Me/Folders';
      }

      print('[FOLDERS] Fetching folders from $foldersEndpoint');
      
      final response = await executeApiRequest(
        ApiRequest(
          method: HttpMethod.get,
          endpoint: foldersEndpoint,
        ),
      );

      if (!response.isSuccess) {
        print('[FOLDERS] Failed to fetch folders: ${response.errorMessage}');
        return {};
      }

      final foldersData = jsonDecode(response.body);
      Map<String, dynamic> foldersMap = {};
      
      if (foldersData is List) {
        for (var folder in foldersData) {
          if (folder is Map<String, dynamic>) {
            final folderId = folder['Id']?.toString();
            if (folderId != null) {
              foldersMap[folderId] = folder;
              print('[FOLDERS] Found folder: ${folder['FolderName']} (ID: $folderId)');
            }
          }
        }
      }

      print('[FOLDERS] Fetched ${foldersMap.length} folders');
      return foldersMap;
    } catch (e) {
      print('[FOLDERS] Error fetching folders: $e');
      return {};
    }
  }

  /// Fetch accounts/enterprise accounts data from Safeguard API
  /// Returns AccountsDataResponse with accounts list and endpoint information
  Future<AccountsDataResponse> getAccountsData() async {
    // Check both password auth token and certificate auth token
    final token = _passwordAuthToken ?? _currentToken;
    
    if (token == null) {
      throw Exception('Not authenticated. Please authenticate first.');
    }

    if (token.isExpired) {
      throw Exception('Token expired. Please re-authenticate.');
    }

    try {
      final isPasswordAuth = _passwordAuthToken != null;
      final authType = isPasswordAuth ? 'PASSWORD' : 'CERTIFICATE';
      final tokenPreview = token.userToken.length > 30 ? token.userToken.substring(0, 30) : token.userToken;
      print('[ACCOUNTS] 📤 Using $authType auth token: $tokenPreview...');
      print('[ACCOUNTS] Fetching account data from /service/core/v4/Me');
      
      // First, get the current user info to check what's available
      final userResponse = await executeApiRequest(
        ApiRequest(
          method: HttpMethod.get,
          endpoint: '/service/core/v4/Me',
        ),
      );

      if (!userResponse.isSuccess) {
        throw Exception('Failed to fetch /service/core/v4/Me: ${userResponse.errorMessage}');
      }

      final userData = jsonDecode(userResponse.body) as Map<String, dynamic>;
      print('[ACCOUNTS] User data keys: ${userData.keys.toList()}');
      print('[ACCOUNTS] User ID from API: ${userData['Id'] ?? userData['UserId'] ?? userData['UserName'] ?? "UNKNOWN"}');
      print('[ACCOUNTS] User DisplayName from API: ${userData['DisplayName'] ?? userData['Name'] ?? "UNKNOWN"}');
      
      // Extract tree from user preferences
      var treeData = _extractTreeFromPreferences(userData);
      
      // Determine which endpoint to use (Accounts or EnterpriseAccounts)
      String accountsEndpoint = '/service/core/v4/Me/Accounts';
      String folderName = 'Private Password Vault';
      
      // Try Accounts first
      var accountsResponse = await executeApiRequest(
        ApiRequest(
          method: HttpMethod.get,
          endpoint: accountsEndpoint,
        ),
      );

      // If Accounts endpoint doesn't exist or doesn't have data, try EnterpriseAccounts
      if (!accountsResponse.isSuccess) {
        print('[ACCOUNTS] /service/core/v4/Me/Accounts not available, trying EnterpriseAccounts');
        accountsEndpoint = '/service/core/v4/Me/EnterpriseAccounts';
        folderName = 'Enterprise Vault';
        accountsResponse = await executeApiRequest(
          ApiRequest(
            method: HttpMethod.get,
            endpoint: accountsEndpoint,
          ),
        );
      }

      if (!accountsResponse.isSuccess) {
        throw Exception('Neither Accounts nor EnterpriseAccounts endpoint available: ${accountsResponse.errorMessage}');
      }

      print('[ACCOUNTS] Successfully fetched from $accountsEndpoint');
      
      // Parse the response - handle both direct list and wrapped list scenarios
      final accountsData = jsonDecode(accountsResponse.body);
      
      List<dynamic> accounts = [];
      if (accountsData is List) {
        accounts = accountsData;
      } else if (accountsData is Map<String, dynamic>) {
        // Sometimes response is wrapped in a property like 'Accounts' or 'Items'
        accounts = accountsData.values.firstWhere(
          (v) => v is List,
          orElse: () => [],
        ) as List<dynamic>;
      }

      print('[ACCOUNTS] Fetched ${accounts.length} accounts from $folderName');
      if (accounts.isNotEmpty) {
        final accountIds = accounts.take(5).map((a) => (a is Map ? a['Id'] ?? a['id'] : 'unknown')).toList();
        print('[ACCOUNTS] Account IDs (first 5): $accountIds');
      }

      return AccountsDataResponse(
        accounts: accounts,
        endpoint: accountsEndpoint,
        folderName: folderName,
        treeData: treeData,
      );
    } catch (e) {
      print('[ACCOUNTS] Error fetching account data: $e');
      throw Exception('Failed to fetch account data: $e');
    }
  }

  /// Fetch password for a specific account
  /// endpoint: '/service/core/v4/Me/Accounts' or '/service/core/v4/Me/EnterpriseAccounts'
  /// accountId: The ID of the account
  Future<Map<String, dynamic>?> getAccountPassword(String endpoint, String accountId) async {
    // Check both password auth token and certificate auth token
    final token = _passwordAuthToken ?? _currentToken;
    
    if (token == null) {
      throw Exception('Not authenticated. Please authenticate first.');
    }

    if (token.isExpired) {
      throw Exception('Token expired. Please re-authenticate.');
    }

    try {
      // Determine the correct endpoint based on the account type
      String passwordEndpoint;
      if (endpoint.contains('EnterpriseAccounts')) {
        passwordEndpoint = '/service/core/v4/Me/EnterpriseAccounts/$accountId/Password';
      } else {
        passwordEndpoint = '/service/core/v4/Me/Accounts/$accountId/Password';
      }

      print('[ACCOUNTS] Fetching password from $passwordEndpoint');
      
      final response = await executeApiRequest(
        ApiRequest(
          method: HttpMethod.get,
          endpoint: passwordEndpoint,
        ),
      );

      if (!response.isSuccess) {
        print('[ACCOUNTS] Failed to fetch password: ${response.errorMessage}');
        return null;
      }

      print('[ACCOUNTS] Password response body type: ${response.body.runtimeType}');
      print('[ACCOUNTS] Password response (first 50 chars): ${response.body.substring(0, math.min(50, response.body.length))}');
      
      // The password endpoint returns either a plain string or a JSON object
      dynamic passwordData;
      try {
        // Try parsing as JSON first
        passwordData = jsonDecode(response.body);
      } catch (e) {
        // If not JSON, treat as plain string password
        passwordData = response.body;
      }
      
      // Normalize to always return a Map with 'Password' key
      if (passwordData is String) {
        print('[ACCOUNTS] Password response is a plain string, wrapping it');
        return {'Password': passwordData};
      } else if (passwordData is Map<String, dynamic>) {
        print('[ACCOUNTS] Successfully fetched password data');
        return passwordData;
      } else {
        print('[ACCOUNTS] Unexpected password response type: ${passwordData.runtimeType}');
        return null;
      }
    } catch (e) {
      print('[ACCOUNTS] Error fetching account password: $e');
      return null;
    }
  }

  /// Get current authentication token
  AuthToken? get currentToken => _currentToken;

  /// Get password authentication token (for preservation across service recreation)
  AuthToken? get passwordAuthToken => _passwordAuthToken;

  /// Check if authenticated (either password or certificate-based)
  bool get isAuthenticated {
    final hasPasswordAuth = _passwordAuthToken != null && !_passwordAuthToken!.isExpired;
    final hasCertAuth = _currentToken != null && !_currentToken!.isExpired;
    return hasPasswordAuth || hasCertAuth;
  }

  /// Store account tree structure in database for a user
  Future<void> storeAccountTree(List<AccountTree> accountTree, {String? usernameParam}) async {
    if (databaseService == null) {
      print('[DB] DatabaseService not available, skipping account tree storage');
      return;
    }

    try {
      final targetUsername = usernameParam ?? username;
      if (targetUsername == null) {
        print('[DB] No username available for storing account tree');
        return;
      }

      // Delete existing tree for this user
      await databaseService!.deleteAccountTreeForUser(targetUsername);
      
      // Insert new tree
      await databaseService!.insertAccountTreeNodes(accountTree);
      print('[DB] Stored ${accountTree.length} account tree nodes for user $targetUsername');
    } catch (e) {
      print('[DB] Error storing account tree: $e');
    }
  }

  /// Store account tree from API response (recursive)
  Future<void> storeAccountTreeFromResponse(
    List<dynamic> accounts, {
    String? usernameParam,
  }) async {
    if (databaseService == null) {
      print('[DB] DatabaseService not available, skipping account tree storage');
      return;
    }

    try {
      final targetUsername = usernameParam ?? username;
      if (targetUsername == null) {
        print('[DB] No username available for storing account tree');
        return;
      }

      final nodesList = <AccountTree>[];
      _buildAccountTreeFromResponse(accounts, targetUsername, null, nodesList, 0);
      
      await storeAccountTree(nodesList, usernameParam: targetUsername);
    } catch (e) {
      print('[DB] Error storing account tree from response: $e');
    }
  }

  /// Recursively build account tree from API response
  void _buildAccountTreeFromResponse(
    List<dynamic> items,
    String username,
    String? parentId,
    List<AccountTree> nodesList,
    int depth,
  ) {
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;

      final node = AccountTree.fromApiResponse(
        username,
        item,
        parentId: parentId,
        depth: depth,
      );
      nodesList.add(node);

      // Recursively add children
      final children = item['Children'] as List<dynamic>?;
      if (children != null && children.isNotEmpty) {
        _buildAccountTreeFromResponse(
          children,
          username,
          item['ID'] as String?,
          nodesList,
          depth + 1,
        );
      }
    }
  }

  /// Cache a retrieved password with encryption
  Future<void> cachePassword({
    required String accountId,
    required String accountName,
    required String passwordValue,
    String? usernameParam,
    DateTime? accountExpirationDate,
    DateTime? accountCreatedDate,
  }) async {
    if (databaseService == null || dataEncryptionService == null) {
      print('[DB] Services not available, skipping password caching');
      return;
    }

    try {
      final targetUsername = usernameParam ?? username;
      print('[DB_CACHE] Starting password cache: accountId=$accountId, username=$targetUsername, accountExpirationDate=$accountExpirationDate');
      
      if (targetUsername == null) {
        print('[DB_CACHE] ERROR: No username available for caching password');
        return;
      }

      // Encrypt the password for this user
      print('[DB_CACHE] Encrypting password for username=$targetUsername');
      final encryptedPassword = dataEncryptionService!.encryptData(
        passwordValue,
        targetUsername,
      );
      print('[DB_CACHE] Encrypted password length=${encryptedPassword.length}');

      // Set cache expiry based on account expiration:
      // - If account has no expiration date, cache indefinitely (expiresAt = null)
      // - If account has expiration date, use that as the cache expiry
      final cacheExpiresAt = accountExpirationDate;
      
      // Create cache entry
      final cachedPassword = CachedPassword(
        id: 0, // Will be auto-generated by SQLite
        username: targetUsername,
        accountId: accountId,
        accountName: accountName,
        encryptedPassword: encryptedPassword,
        cachedAt: DateTime.now(),
        expiresAt: cacheExpiresAt,
        accountExpirationDate: accountExpirationDate,
        accountCreatedDate: accountCreatedDate,
      );

      print('[DB_CACHE] Inserting into database: username=$targetUsername, accountId=$accountId, accountExpirationDate=$accountExpirationDate');
      // Store in database
      await databaseService!.insertCachedPassword(cachedPassword);
      print('[DB_CACHE] ✅ Successfully cached password for account $accountId with username=$targetUsername');
    } catch (e) {
      print('[DB_CACHE] ❌ CRITICAL ERROR caching password for account $accountId: $e');
      print('[DB_CACHE] Stack trace: $e');
      rethrow; // Re-throw so caller knows the cache failed
    }
  }

  /// Get cached password if available and not expired
  Future<String?> getCachedPassword({
    required String accountId,
    String? usernameParam,
    bool isOfflineMode = false,
  }) async {
    if (databaseService == null || dataEncryptionService == null) {
      print('[DB_RETRIEVE] ❌ Services not available: db=${databaseService!=null}, encryption=${dataEncryptionService!=null}');
      return null;
    }

    try {
      final targetUsername = usernameParam ?? username;
      print('[DB_RETRIEVE] Looking for cached password: accountId=$accountId, username=$targetUsername, param=$usernameParam, serviceUsername=$username, isOfflineMode=$isOfflineMode');
      
      if (targetUsername == null) {
        print('[DB_RETRIEVE] ❌ ERROR: No username available (param=$usernameParam, service=$username)');
        return null;
      }

      print('[DB_RETRIEVE] Calling databaseService.getCachedPassword($targetUsername, $accountId)');
      final cached = await databaseService!.getCachedPassword(
        targetUsername,
        accountId,
      );

      print('[DB_RETRIEVE] Database returned: cached=${cached != null ? "FOUND" : "NULL"}');
      
      if (cached == null) {
        print('[DB_RETRIEVE] ❌ No cached password found in database for accountId=$accountId, username=$targetUsername');
        return null;
      }
      
      print('[DB_RETRIEVE] Found cached password entry: cachedAt=${cached.cachedAt}, expiresAt=${cached.expiresAt}, accountExpirationDate=${cached.accountExpirationDate}, hasEncrypted=${cached.encryptedPassword.isNotEmpty}');

      // Check if the ACCOUNT itself is expired (based on account's ExpirationDate)
      // In offline mode, still show the password but with a warning
      // In online mode, also still show the password (don't block it completely)
      final isAccountExpired = cached.isAccountExpired;
      
      if (isAccountExpired && !isOfflineMode) {
        print('[DB_RETRIEVE] ⏰ ACCOUNT EXPIRED for accountId=$accountId (account expires at ${cached.accountExpirationDate})');
        // Still decrypt password, but mark it as from an expired account
        // The UI will show a warning but still display the password
      }

      // Check if the CACHE itself (password storage) is expired
      // In offline mode, ignore cache expiry - use whatever cached data is available
      // In online mode, check if cache has expired
      if (cached.isExpired && !isOfflineMode) {
        print('[DB_RETRIEVE] ⏰ CACHE EXPIRED for accountId=$accountId (cache expires at ${cached.expiresAt})');
        return null;
      }
      
      if (cached.isExpired && isOfflineMode) {
        print('[DB_RETRIEVE] ⏰ CACHE EXPIRED but in offline mode - using anyway for accountId=$accountId');
      }

      // Decrypt the password
      print('[DB_RETRIEVE] Decrypting password for username=$targetUsername, encrypted length=${cached.encryptedPassword.length}');
      final decrypted = dataEncryptionService!.decryptData(
        cached.encryptedPassword,
        targetUsername,
      );
      
      if (isAccountExpired) {
        // Return password with expiration marker prefix for UI to handle
        final result = 'ACCOUNT_EXPIRED:${cached.accountExpirationDate}:$decrypted';
        print('[DB_RETRIEVE] ✅ Retrieved decrypted password for accountId=$accountId (account expired, password length=${decrypted.length})');
        return result;
      }
      
      print('[DB_RETRIEVE] ✅ Successfully retrieved and decrypted password for accountId=$accountId (decrypted length=${decrypted.length})');
      return decrypted;
    } catch (e) {
      print('[DB_RETRIEVE] ❌ Error retrieving cached password: $e');
      print('[DB_RETRIEVE] Stack trace: ${StackTrace.current}');
      return null;
    }
  }

  /// Clear all cached passwords for the current user
  Future<void> clearCachedPasswords({String? usernameParam}) async {
    if (databaseService == null) return;

    try {
      final targetUsername = usernameParam ?? username;
      if (targetUsername == null) return;

      await databaseService!.deleteCachedPasswordsForUser(targetUsername);
      print('[DB] Cleared cached passwords for user $targetUsername');
    } catch (e) {
      print('[DB] Error clearing cached passwords: $e');
    }
  }

  /// Clear expired cached passwords
  Future<void> clearExpiredCachedPasswords() async {
    if (databaseService == null || username == null) return;

    try {
      await databaseService!.clearExpiredCachedPasswords(username!);
      print('[DB] Cleared expired cached passwords for user=$username');
    } catch (e) {
      print('[DB] Error clearing expired passwords: $e');
    }
  }

  /// Clear authentication
  void logout() {
    final ctPreview = _currentToken?.userToken.substring(0, 20) ?? "null";
    final ptPreview = _passwordAuthToken?.userToken.substring(0, 20) ?? "null";
    print('[AUTH] 🔑 LOGOUT STARTING: _currentToken=$ctPreview..., _passwordAuthToken=$ptPreview...');
    _currentToken = null;
    _passwordAuthToken = null;
    print('[AUTH] 🔑 LOGOUT COMPLETE: _currentToken=$_currentToken, _passwordAuthToken=$_passwordAuthToken');
  }

  /// Extract tree structure from user preferences
  Map<String, dynamic>? _extractTreeFromPreferences(Map<String, dynamic> userData) {
    try {
      final preferences = userData['Preferences'];
      if (preferences is! List) {
        print('[TREE] No Preferences found in user data');
        return null;
      }

      // Find the enterpriseVault.tree preference
      Map<String, dynamic>? treePreference;
      for (var pref in preferences) {
        if (pref is Map<String, dynamic> && pref['Name'] == 'enterpriseVault.tree') {
          treePreference = pref;
          break;
        }
      }

      if (treePreference == null) {
        print('[TREE] No enterpriseVault.tree preference found');
        return null;
      }

      final treeString = treePreference['Value'];
      if (treeString is! String) {
        print('[TREE] Tree preference Value is not a string');
        return null;
      }

      // Parse the tree JSON string
      final treeParsed = jsonDecode(treeString);
      print('[TREE] Successfully parsed tree structure');
      
      // Log RAW tree structure for debugging folder issues
      print('[TREE] ====== RAW TREE STRUCTURE FROM API ======');
      try {
        print('[TREE] Raw JSON: $treeParsed');
        if (treeParsed is List) {
          print('[TREE] Tree is List with ${(treeParsed).length} root nodes');
          for (int i = 0; i < (treeParsed).length; i++) {
            final node = (treeParsed)[i];
            if (node is Map<String, dynamic>) {
              print('[TREE] Root node [$i]: name=${node['folderName'] ?? node['Name'] ?? 'Unknown'}, keys=${node.keys.toList()}');
              _logTreeNode(node, '  ');
            }
          }
        } else if (treeParsed is Map<String, dynamic>) {
          print('[TREE] Tree is Map with keys=${treeParsed.keys.toList()}');
          if (treeParsed.containsKey('tree')) {
            final tree = treeParsed['tree'];
            if (tree is List) {
              print('[TREE] tree.value has ${(tree).length} items');
              for (int i = 0; i < (tree).length; i++) {
                final node = (tree)[i];
                if (node is Map<String, dynamic>) {
                  print('[TREE] Root node [$i]: name=${node['folderName'] ?? node['Name'] ?? 'Unknown'}, keys=${node.keys.toList()}');
                  _logTreeNode(node, '  ');
                }
              }
            }
          }
        }
      } catch (e) {
        print('[TREE] Could not log tree structure: $e');
      }
      print('[TREE] ====== END RAW TREE ======');
      
      return {'tree': treeParsed};
    } catch (e) {
      print('[TREE] Error extracting tree from preferences: $e');
      return null;
    }
  }

  /// Recursively log tree node structure for debugging
  void _logTreeNode(Map<String, dynamic> node, String indent) {
    final name = node['folderName'] ?? node['Name'] ?? 'Unknown';
    final hasFolderId = node.containsKey('folderId');
    final hasFolderName = node.containsKey('folderName');
    final hasId = node.containsKey('Id');
    final hasChildren = (node['children'] as List?)?.isNotEmpty ?? false;
    final childCount = (node['children'] as List?)?.length ?? 0;
    
    print('[TREE] $indent- "$name" (type=${hasFolderId ? 'folderId' : hasFolderName ? 'folderName' : 'other'}, Id=$hasId, children=$childCount)');
    
    if (hasChildren) {
      final children = node['children'] as List;
      for (int i = 0; i < children.length; i++) {
        final child = children[i];
        if (child is Map<String, dynamic>) {
          _logTreeNode(child, '$indent  ');
        }
      }
    }
  }
}

/// Data class to hold accounts response with endpoint information
class AccountsDataResponse {
  final List<dynamic> accounts;
  final String endpoint; // '/service/core/v4/Me/Accounts' or '/service/core/v4/Me/EnterpriseAccounts'
  final String folderName; // 'Private Password Vault' or 'Enterprise Vault'
  final Map<String, dynamic>? treeData; // Tree structure from preferences

  AccountsDataResponse({
    required this.accounts,
    required this.endpoint,
    required this.folderName,
    this.treeData,
  });
}
