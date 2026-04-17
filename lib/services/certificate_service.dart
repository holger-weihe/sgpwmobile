import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

class CertificateService {
  static const String _certificateKeyPrefix = 'safeguard_certificate_';
  static const String _privateKeyKeyPrefix = 'safeguard_private_key_';
  
  // Legacy keys for backward compatibility
  static const String _legacyCertificateKey = 'safeguard_certificate';
  static const String _legacyPrivateKeyKey = 'safeguard_private_key';

  final FlutterSecureStorage _storage;

  CertificateService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Generate per-user key for storing certificate
  String _getCertificateKey(String username) => '$_certificateKeyPrefix$username';

  /// Generate per-user key for storing private key
  String _getPrivateKeyKey(String username) => '$_privateKeyKeyPrefix$username';

  /// Save certificate and private key to secure storage (per-user)
  Future<void> saveCertificateAndKey({
    required String certificate,
    required String privateKey,
    String? username,
  }) async {
    try {
      final certKey = username != null ? _getCertificateKey(username) : _legacyCertificateKey;
      final keyKey = username != null ? _getPrivateKeyKey(username) : _legacyPrivateKeyKey;
      
      await Future.wait([
        _storage.write(key: certKey, value: certificate),
        _storage.write(key: keyKey, value: privateKey),
      ]);
    } catch (e) {
      throw Exception('Failed to save certificate: $e');
    }
  }

  /// Retrieve certificate from secure storage (per-user)
  Future<String?> getCertificate({String? username}) async {
    try {
      final key = username != null ? _getCertificateKey(username) : _legacyCertificateKey;
      return await _storage.read(key: key);
    } catch (e) {
      throw Exception('Failed to retrieve certificate: $e');
    }
  }

  /// Retrieve private key from secure storage (per-user)
  Future<String?> getPrivateKey({String? username}) async {
    try {
      final key = username != null ? _getPrivateKeyKey(username) : _legacyPrivateKeyKey;
      return await _storage.read(key: key);
    } catch (e) {
      throw Exception('Failed to retrieve private key: $e');
    }
  }

  /// Check if certificate and key are stored (per-user)
  Future<bool> hasStoredCertificates({String? username}) async {
    try {
      final cert = await getCertificate(username: username);
      final key = await getPrivateKey(username: username);
      return cert != null && key != null;
    } catch (e) {
      return false;
    }
  }

  /// Delete stored certificate and key (per-user)
  Future<void> deleteCertificates({String? username}) async {
    try {
      final certKey = username != null ? _getCertificateKey(username) : _legacyCertificateKey;
      final keyKey = username != null ? _getPrivateKeyKey(username) : _legacyPrivateKeyKey;
      
      await Future.wait([
        _storage.delete(key: certKey),
        _storage.delete(key: keyKey),
      ]);
    } catch (e) {
      throw Exception('Failed to delete certificates: $e');
    }
  }

  /// Validate certificate format (basic PEM check)
  static bool isValidPemCertificate(String content) {
    return content.contains('-----BEGIN CERTIFICATE-----') &&
        content.contains('-----END CERTIFICATE-----');
  }

  /// Validate private key format (basic PEM check)
  static bool isValidPemPrivateKey(String content) {
    return (content.contains('-----BEGIN RSA PRIVATE KEY-----') ||
            content.contains('-----BEGIN PRIVATE KEY-----')) &&
        (content.contains('-----END RSA PRIVATE KEY-----') ||
            content.contains('-----END PRIVATE KEY-----'));
  }

  /// Get the raw certificate content without PEM headers
  static String getRawCertificateContent(String pemCert) {
    return pemCert
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll(RegExp(r'\s'), '');
  }

  /// Simple certificate identifier (for debugging/logging)
  static String getCertificateIdentifier(String pemCert) {
    final raw = getRawCertificateContent(pemCert);
    if (raw.length > 32) {
      return raw.substring(0, 32);
    }
    return raw;
  }

  /// Calculate SHA-1 thumbprint of the certificate (DER format)
  /// Returns the thumbprint as a hex string (lowercase, no separators)
  static String getCertificateThumbprint(String pemCert) {
    try {
      // Extract base64 content from PEM format
      final base64Content = pemCert
          .replaceAll('-----BEGIN CERTIFICATE-----', '')
          .replaceAll('-----END CERTIFICATE-----', '')
          .replaceAll(RegExp(r'\s'), '');
      
      // Decode base64 to get DER bytes
      final derBytes = base64.decode(base64Content);
      
      // Calculate SHA-1 hash of DER bytes
      final sha1Hash = sha1.convert(derBytes);
      
      // Return as hex string
      return sha1Hash.toString();
    } catch (e) {
      print('[CERT] Error calculating thumbprint: $e');
      return '';
    }
  }

  /// Get thumbprint formatted with colons (XX:XX:XX:...)
  static String getCertificateThumbprintFormatted(String pemCert) {
    final thumbprint = getCertificateThumbprint(pemCert);
    if (thumbprint.isEmpty) return '';
    
    // Add colons between each pair of hex digits
    return RegExp(r'.{1,2}')
        .allMatches(thumbprint)
        .map((m) => m.group(0))
        .join(':')
        .toUpperCase();
  }
}
