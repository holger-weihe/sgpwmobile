import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../models/user.dart';
import 'database_service.dart';

/// Service for handling biometric authentication
class BiometricAuthService {
  final DatabaseService _databaseService;
  final LocalAuthentication _localAuth = LocalAuthentication();
  static const platform = MethodChannel('com.example.sgpwmobile/biometric');

  BiometricAuthService({required DatabaseService databaseService})
      : _databaseService = databaseService;

  /// Check if device supports biometric authentication
  Future<bool> canUseBiometric() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      return canCheck;
    } catch (e) {
      return false;
    }
  }

  /// Get list of available biometric types on device
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }

  /// Enroll biometric for a user (activate biometric auth)
  /// Note: Does not require authentication during setup - user can authenticate when logging in
  Future<BiometricResult> enrollBiometric({
    required String username,
  }) async {
    try {
      // Simply enable biometric support without requiring an authentication test
      // The actual authentication happens during login
      final canUseBio = await canUseBiometric();
      
      final user = await _databaseService.getUser(username);
      if (user == null) {
        return BiometricResult(
          success: false,
          message: 'User not found',
        );
      }

      final updatedUser = user.copyWith(biometricEnabled: true);
      await _databaseService.updateUser(updatedUser);

      return BiometricResult(
        success: true,
        message: canUseBio 
            ? 'Biometric login enabled successfully! Your fingerprint will be required for authentication.'
            : 'Biometric support enabled. Please enroll fingerprints in device settings.',
      );
    } catch (e) {
      print('Error enrolling biometric: $e');
      return BiometricResult(
        success: false,
        message: 'Failed to enroll biometric: ${e.toString()}',
      );
    }
  }

  /// Disable biometric for a user
  Future<BiometricResult> disableBiometric({
    required String username,
  }) async {
    try {
      final user = await _databaseService.getUser(username);
      if (user == null) {
        return BiometricResult(
          success: false,
          message: 'User not found',
        );
      }

      final updatedUser = user.copyWith(biometricEnabled: false);
      await _databaseService.updateUser(updatedUser);

      return BiometricResult(
        success: true,
        message: 'Biometric authentication disabled',
      );
    } catch (e) {
      return BiometricResult(
        success: false,
        message: 'Failed to disable biometric: ${e.toString()}',
      );
    }
  }

  /// Authenticate user with biometric
  /// This is called when user wants to login with biometric instead of password
  Future<BiometricAuthResult> authenticateUser({
    required String username,
  }) async {
    try {
      // Check if user exists and has biometric enabled
      final user = await _databaseService.getUser(username);
      if (user == null) {
        return BiometricAuthResult(
          success: false,
          message: 'User not found',
        );
      }

      if (!user.biometricEnabled) {
        return BiometricAuthResult(
          success: false,
          message: 'Biometric authentication is not enabled for this user',
        );
      }

      // Check biometric availability first
      print('Checking biometric availability...');
      final canCheck = await _localAuth.canCheckBiometrics;
      if (!canCheck) {
        print('Device cannot check biometrics');
        return BiometricAuthResult(
          success: false,
          message: 'Biometric authentication is not available on this device',
        );
      }

      final availableBiometrics = await _localAuth.getAvailableBiometrics();
      print('Available biometrics: $availableBiometrics');
      if (availableBiometrics.isEmpty) {
        return BiometricAuthResult(
          success: false,
          message: 'No biometric data enrolled on device. Please enroll fingerprints first.',
        );
      }

      // Authenticate with biometric
      print('Attempting biometric authentication for user: $username');
      final isAuthenticated = await _authenticateWithBiometric(
        reason: 'Authenticate as $username',
        sensitiveTransaction: true,
      );

      if (!isAuthenticated) {
        return BiometricAuthResult(
          success: false,
          message: 'Biometric authentication failed. Please try again or use password login.',
        );
      }

      // Update last login time
      await _databaseService.updateLastLogin(username);
      final updatedUser = await _databaseService.getUser(username);

      return BiometricAuthResult(
        success: true,
        message: 'Biometric authentication successful',
        user: updatedUser,
      );
    } catch (e) {
      print('Error in authenticateUser: $e');
      return BiometricAuthResult(
        success: false,
        message: 'Authentication error: ${e.toString()}',
      );
    }
  }

  /// Perform biometric authentication
  Future<bool> _authenticateWithBiometric({
    required String reason,
    bool sensitiveTransaction = false,
  }) async {
    try {
      print('Starting biometric authentication: $reason');
      
      // Try native method channel first (AndroidX BiometricPrompt)
      try {
        print('Attempting native biometric authentication...');
        final result = await platform.invokeMethod<bool>(
          'authenticate',
          {'reason': reason},
        );
        print('Native biometric authentication result: $result');
        if (result != null) {
          return result;
        }
      } catch (e) {
        print('Native biometric authentication failed: $e');
        print('Falling back to local_auth plugin...');
      }

      // Fallback to local_auth if native channel fails
      print('Checking if device can check biometrics...');
      
      final canCheck = await _localAuth.canCheckBiometrics;
      print('canCheckBiometrics: $canCheck');
      
      if (!canCheck) {
        print('Device cannot check biometrics');
        return false;
      }
      
      print('Getting available biometrics...');
      final availableBiometrics = await _localAuth.getAvailableBiometrics();
      print('Available biometrics: $availableBiometrics');
      
      if (availableBiometrics.isEmpty) {
        print('No biometrics available on device');
        return false;
      }
      
      print('Calling local_auth authenticate with reason: $reason');
      final result = await _localAuth.authenticate(
        localizedReason: reason,
      );
      print('Biometric authentication result: $result');
      return result;
    } on PlatformException catch (e) {
      print('PlatformException in biometric auth: ${e.code} - ${e.message}');
      return false;
    } catch (e) {
      print('Biometric authentication error: $e');
      print('Error type: ${e.runtimeType}');
      return false;
    }
  }

  /// Check if a specific biometric type is available
  Future<bool> isBiometricTypeAvailable(BiometricType type) async {
    try {
      final available = await _localAuth.getAvailableBiometrics();
      return available.contains(type);
    } catch (e) {
      return false;
    }
  }
}

/// Result of biometric operation
class BiometricResult {
  final bool success;
  final String message;

  BiometricResult({
    required this.success,
    required this.message,
  });

  @override
  String toString() => 'BiometricResult(success: $success, message: $message)';
}

/// Result of biometric authentication
class BiometricAuthResult {
  final bool success;
  final String message;
  final User? user;

  BiometricAuthResult({
    required this.success,
    required this.message,
    this.user,
  });

  @override
  String toString() =>
      'BiometricAuthResult(success: $success, message: $message)';
}
