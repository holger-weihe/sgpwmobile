import 'dart:convert';

class AuthToken {
  final String userToken;
  final String status;
  final int webClientInactivityTimeout;
  final int desktopClientInactivityTimeout;
  final DateTime issuedAt;
  final DateTime expiresAt;

  AuthToken({
    required this.userToken,
    required this.status,
    required this.webClientInactivityTimeout,
    required this.desktopClientInactivityTimeout,
    required this.issuedAt,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get isAboutToExpire {
    final fiveMinutesFromNow = DateTime.now().add(const Duration(minutes: 5));
    return expiresAt.isBefore(fiveMinutesFromNow);
  }

  /// Extract the actual expiration time from the JWT token's 'exp' claim
  static DateTime? _extractExpiryFromJwt(String jwt) {
    try {
      // JWT format: header.payload.signature
      final parts = jwt.split('.');
      if (parts.length != 3) {
        return null;
      }
      
      // Decode the payload (second part)
      // Add padding if necessary
      var payload = parts[1];
      payload += List<String>.filled((4 - payload.length % 4) % 4, '=').join();
      
      final decoded = utf8.decode(base64Url.decode(payload));
      final data = jsonDecode(decoded) as Map<String, dynamic>;
      
      final exp = data['exp'] as int?;
      if (exp != null) {
        // exp is in seconds since epoch
        return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      }
    } catch (e) {
      print('[AUTH] Error extracting expiry from JWT: $e');
    }
    return null;
  }

  factory AuthToken.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    
    // Handle both OAuth2 format (access_token) and Safeguard format (UserToken)
    final userToken = (json['UserToken'] as String?) ?? (json['access_token'] as String?);
    if (userToken == null) {
      throw FormatException('No token found in response. Expected UserToken or access_token.');
    }
    
    // Try to extract actual expiration from JWT
    DateTime expiresAt = _extractExpiryFromJwt(userToken) ?? 
        now.add(const Duration(hours: 24)); // Fallback to 24 hours if parsing fails

    return AuthToken(
      userToken: userToken,
      status: json['Status'] as String? ?? 'Unknown',
      webClientInactivityTimeout:
          json['WebClientInactivityTimeout'] as int? ?? 2880,
      desktopClientInactivityTimeout:
          json['DesktopClientInactivityTimeout'] as int? ?? 1440,
      issuedAt: now,
      expiresAt: expiresAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'UserToken': userToken,
      'Status': status,
      'WebClientInactivityTimeout': webClientInactivityTimeout,
      'DesktopClientInactivityTimeout': desktopClientInactivityTimeout,
    };
  }
}
