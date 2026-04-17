import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'dart:io';

class AvatarService {
  static const String _prefix = 'user_avatar_';
  final FlutterSecureStorage _secureStorage;

  AvatarService() : _secureStorage = const FlutterSecureStorage();

  /// Get avatar for user as base64 encoded string
  Future<String?> getAvatar(String username) async {
    final key = _getAvatarKey(username);
    try {
      return await _secureStorage.read(key: key);
    } catch (e) {
      print('Error retrieving avatar for $username: $e');
      return null;
    }
  }

  /// Save avatar from file path as base64 encoded string
  Future<void> saveAvatar(String username, String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final base64String = base64Encode(bytes);
      final key = _getAvatarKey(username);
      await _secureStorage.write(key: key, value: base64String);
    } catch (e) {
      print('Error saving avatar for $username: $e');
      rethrow;
    }
  }

  /// Delete avatar for user
  Future<void> deleteAvatar(String username) async {
    final key = _getAvatarKey(username);
    try {
      await _secureStorage.delete(key: key);
    } catch (e) {
      print('Error deleting avatar for $username: $e');
    }
  }

  /// Decode base64 avatar to bytes
  static List<int>? decodeAvatar(String base64String) {
    try {
      return base64Decode(base64String);
    } catch (e) {
      print('Error decoding avatar: $e');
      return null;
    }
  }

  String _getAvatarKey(String username) => '$_prefix$username';
}
