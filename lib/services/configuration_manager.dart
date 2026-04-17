import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/safeguard_config.dart';

class ConfigurationManager extends ChangeNotifier {
  static const String _configKeyPrefix = 'safeguard_config_';
  static const String _legacyConfigKey = 'safeguard_config';
  
  final FlutterSecureStorage _storage;
  
  String? _currentUsername;
  SafeguardConfig? _config;
  String? _lastError;

  ConfigurationManager({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  SafeguardConfig? get config => _config;
  String? get lastError => _lastError;
  bool get hasConfig => _config != null;
  String? get currentUsername => _currentUsername;

  /// Generate per-user key for storing configuration
  String _getConfigKey(String username) => '$_configKeyPrefix$username';

  /// Load configuration for a specific user
  Future<void> loadConfig({String? username}) async {
    try {
      _lastError = null;
      _currentUsername = username;
      
      final key = username != null ? _getConfigKey(username) : _legacyConfigKey;
      final configJson = await _storage.read(key: key);
      
      if (configJson != null) {
        final jsonData = jsonDecode(configJson) as Map<String, dynamic>;
        _config = SafeguardConfig.fromJson(jsonData);
      } else {
        _config = null;
      }
      
      notifyListeners();
    } catch (e) {
      _lastError = 'Failed to load configuration: $e';
      notifyListeners();
    }
  }

  /// Save configuration for a specific user
  Future<void> saveConfig(SafeguardConfig newConfig, {String? username}) async {
    try {
      _lastError = null;
      _config = newConfig;
      _currentUsername = username;
      
      final key = username != null ? _getConfigKey(username) : _legacyConfigKey;
      await _storage.write(
        key: key,
        value: jsonEncode(newConfig.toJson()),
      );
      
      notifyListeners();
    } catch (e) {
      _lastError = 'Failed to save configuration: $e';
      notifyListeners();
      rethrow;
    }
  }

  /// Delete stored configuration for a specific user
  Future<void> deleteConfig({String? username}) async {
    try {
      _lastError = null;
      
      final key = username != null ? _getConfigKey(username) : _legacyConfigKey;
      await _storage.delete(key: key);
      
      if (username == _currentUsername) {
        _config = null;
        _currentUsername = null;
      }
      
      notifyListeners();
    } catch (e) {
      _lastError = 'Failed to delete configuration: $e';
      notifyListeners();
    }
  }

  /// Update server address for a specific user
  Future<void> updateServerAddress(String newAddress, {String? username}) async {
    if (_config == null) {
      _lastError = 'No configuration loaded';
      notifyListeners();
      return;
    }

    try {
      _lastError = null;
      final updatedConfig = SafeguardConfig(
        serverAddress: newAddress,
        certificateKey: _config!.certificateKey,
        privateKeyKey: _config!.privateKeyKey,
      );
      
      await saveConfig(updatedConfig, username: username ?? _currentUsername);
    } catch (e) {
      _lastError = 'Failed to update server address: $e';
      notifyListeners();
    }
  }

  /// Clear current configuration (used on logout)
  void clearCurrentConfig() {
    _config = null;
    _currentUsername = null;
    notifyListeners();
  }
}
