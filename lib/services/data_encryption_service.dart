import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

/// Service for encrypting and decrypting sensitive user data
class DataEncryptionService {
  /// Generate a user-specific encryption key based on username
  /// This ensures each user's data is encrypted with a different key
  encrypt.Key _generateKey(String username) {
    // Create a deterministic key based on username
    // Using SHA256 to create a consistent 32-byte key
    final bytes = utf8.encode(username);
    final digest = sha256.convert(bytes);
    
    // Take first 32 bytes for AES-256
    final keyBytes = Uint8List.fromList(digest.bytes.sublist(0, 32));
    return encrypt.Key(keyBytes);
  }

  /// Generate a random IV for each encryption
  encrypt.IV _generateIV() {
    return encrypt.IV.fromSecureRandom(16);
  }

  /// Encrypt sensitive data (like cached passwords)
  /// Returns a JSON string containing the encrypted data and IV
  String encryptData(String plaintext, String username) {
    try {
      final key = _generateKey(username);
      final iv = _generateIV();
      final encrypter = encrypt.Encrypter(encrypt.AES(key));

      final encrypted = encrypter.encrypt(plaintext, iv: iv);

      // Store encrypted text and IV as JSON
      final encryptedData = {
        'encrypted': encrypted.base64,
        'iv': base64Url.encode(iv.bytes),
      };

      return jsonEncode(encryptedData);
    } catch (e) {
      throw EncryptionException('Failed to encrypt data: ${e.toString()}');
    }
  }

  /// Decrypt sensitive data encrypted with encryptData
  String decryptData(String encryptedJson, String username) {
    try {
      final key = _generateKey(username);
      final encrypter = encrypt.Encrypter(encrypt.AES(key));

      // Parse the JSON containing encrypted data and IV
      final encryptedData = jsonDecode(encryptedJson) as Map<String, dynamic>;
      final encryptedText = encryptedData['encrypted'] as String;
      final ivBase64 = encryptedData['iv'] as String;

      // Decode IV from base64
      final ivBytes = base64Url.decode(ivBase64);
      final iv = encrypt.IV(ivBytes);

      // Decrypt
      final decrypted = encrypter.decrypt64(encryptedText, iv: iv);
      return decrypted;
    } catch (e) {
      throw EncryptionException('Failed to decrypt data: ${e.toString()}');
    }
  }

  /// Encrypt a map of data to JSON
  String encryptMap(Map<String, dynamic> data, String username) {
    try {
      final jsonString = jsonEncode(data);
      return encryptData(jsonString, username);
    } catch (e) {
      throw EncryptionException('Failed to encrypt map: ${e.toString()}');
    }
  }

  /// Decrypt a JSON string back to a map
  Map<String, dynamic> decryptMap(String encryptedJson, String username) {
    try {
      final jsonString = decryptData(encryptedJson, username);
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      throw EncryptionException('Failed to decrypt map: ${e.toString()}');
    }
  }

  /// Encrypt a list of strings
  String encryptList(List<String> data, String username) {
    try {
      final jsonString = jsonEncode(data);
      return encryptData(jsonString, username);
    } catch (e) {
      throw EncryptionException('Failed to encrypt list: ${e.toString()}');
    }
  }

  /// Decrypt a JSON string back to a list of strings
  List<String> decryptList(String encryptedJson, String username) {
    try {
      final jsonString = decryptData(encryptedJson, username);
      return List<String>.from(jsonDecode(jsonString) as List);
    } catch (e) {
      throw EncryptionException('Failed to decrypt list: ${e.toString()}');
    }
  }

  /// Validate that encrypted data can be decrypted with the given username
  /// Useful for verifying correct key/username combination
  bool validateEncryption(String encryptedJson, String username) {
    try {
      decryptData(encryptedJson, username);
      return true;
    } catch (e) {
      return false;
    }
  }
}

/// Exception for encryption-related errors
class EncryptionException implements Exception {
  final String message;

  EncryptionException(this.message);

  @override
  String toString() => 'EncryptionException: $message';
}
