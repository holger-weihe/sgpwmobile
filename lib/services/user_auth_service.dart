import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/user.dart';
import 'database_service.dart';

/// Service for handling user authentication and password management
class UserAuthService {
  final DatabaseService _databaseService;

  // Password policy constants
  static const int minPasswordLength = 8;
  static const int hashIterations = 10000; // PBKDF2-style iterations

  UserAuthService({required DatabaseService databaseService})
      : _databaseService = databaseService;

  /// Validates password against policy requirements
  /// Returns a validation result with any error message
  ValidationResult validatePassword(String password) {
    if (password.isEmpty) {
      return ValidationResult(
        isValid: false,
        message: 'Password cannot be empty',
      );
    }

    if (password.length < minPasswordLength) {
      return ValidationResult(
        isValid: false,
        message: 'Password must be at least $minPasswordLength characters long',
      );
    }

    final hasUppercase = password.contains(RegExp(r'[A-Z]'));
    final hasLowercase = password.contains(RegExp(r'[a-z]'));
    final hasDigits = password.contains(RegExp(r'\d'));
    final hasSpecialChars = password.contains(RegExp(r'[!@#$%^&*()_\-+=\[\]{}:;,.<>?/\\|`~]'));

    if (!hasUppercase) {
      return ValidationResult(
        isValid: false,
        message: 'Password must contain at least one uppercase letter',
      );
    }

    if (!hasLowercase) {
      return ValidationResult(
        isValid: false,
        message: 'Password must contain at least one lowercase letter',
      );
    }

    if (!hasDigits) {
      return ValidationResult(
        isValid: false,
        message: 'Password must contain at least one digit',
      );
    }

    if (!hasSpecialChars) {
      return ValidationResult(
        isValid: false,
        message: 'Password must contain at least one special character',
      );
    }

    return ValidationResult(isValid: true);
  }

  /// Hash a password with salt using PBKDF2-style approach
  /// Returns a hash string in format: salt:hash
  String _hashPassword(String password, {String? salt}) {
    salt ??= _generateSalt();

    // Simulate PBKDF2 with multiple SHA256 iterations
    String hash = password;
    for (int i = 0; i < hashIterations; i++) {
      hash = sha256.convert(utf8.encode(hash + salt)).toString();
    }

    return '$salt:$hash';
  }

  /// Generate a random salt
  String _generateSalt() {
    final random = DateTime.now().millisecondsSinceEpoch.toString() +
        DateTime.now().microsecond.toString();
    return sha256.convert(utf8.encode(random)).toString().substring(0, 16);
  }

  /// Verify a password against its hash
  bool _verifyPassword(String password, String passwordHash) {
    final parts = passwordHash.split(':');
    if (parts.length != 2) {
      return false;
    }

    final salt = parts[0];
    final storedHash = parts[1];

    final computedHash = _hashPassword(password, salt: salt);
    final computedHashParts = computedHash.split(':');
    final computedHashValue = computedHashParts[1];

    return computedHashValue == storedHash;
  }

  /// Register a new user
  /// Returns RegisterResult with success/error information
  Future<AuthResult> register({
    required String username,
    required String password,
    String? serverAddress,
  }) async {
    try {
      // Validate inputs
      if (username.isEmpty || username.length < 3) {
        return AuthResult(
          success: false,
          message: 'Username must be at least 3 characters long',
        );
      }

      // Check if username already exists
      final existingUser = await _databaseService.getUser(username);
      if (existingUser != null) {
        return AuthResult(
          success: false,
          message: 'Username already exists',
        );
      }

      // Validate password
      final passwordValidation = validatePassword(password);
      if (!passwordValidation.isValid) {
        return AuthResult(
          success: false,
          message: passwordValidation.message,
        );
      }

      // Hash the password
      final passwordHash = _hashPassword(password);

      // Create new user
      final user = User(
        username: username,
        passwordHash: passwordHash,
        serverAddress: serverAddress,
        biometricEnabled: false,
        createdAt: DateTime.now(),
      );

      // Save to database
      await _databaseService.insertUser(user);

      return AuthResult(
        success: true,
        message: 'User registered successfully',
        user: user,
      );
    } catch (e) {
      return AuthResult(
        success: false,
        message: 'Registration failed: ${e.toString()}',
      );
    }
  }

  /// Login a user with password
  /// Returns AuthResult with user if successful
  Future<AuthResult> login({
    required String username,
    required String password,
  }) async {
    try {
      // Retrieve user from database
      final user = await _databaseService.getUser(username);

      if (user == null) {
        return AuthResult(
          success: false,
          message: 'User not found',
        );
      }

      // Verify password
      if (!_verifyPassword(password, user.passwordHash)) {
        return AuthResult(
          success: false,
          message: 'Invalid password',
        );
      }

      // Update last login time
      await _databaseService.updateLastLogin(username);

      // Return updated user
      final updatedUser = await _databaseService.getUser(username);

      return AuthResult(
        success: true,
        message: 'Login successful',
        user: updatedUser,
      );
    } catch (e) {
      return AuthResult(
        success: false,
        message: 'Login failed: ${e.toString()}',
      );
    }
  }

  /// Change user's password
  Future<AuthResult> changePassword({
    required String username,
    required String oldPassword,
    required String newPassword,
  }) async {
    try {
      // Retrieve user
      final user = await _databaseService.getUser(username);

      if (user == null) {
        return AuthResult(
          success: false,
          message: 'User not found',
        );
      }

      // Verify old password
      if (!_verifyPassword(oldPassword, user.passwordHash)) {
        return AuthResult(
          success: false,
          message: 'Current password is incorrect',
        );
      }

      // Validate new password
      final passwordValidation = validatePassword(newPassword);
      if (!passwordValidation.isValid) {
        return AuthResult(
          success: false,
          message: passwordValidation.message,
        );
      }

      // Prevent reusing the same password
      if (oldPassword == newPassword) {
        return AuthResult(
          success: false,
          message: 'New password must be different from current password',
        );
      }

      // Hash the new password
      final newPasswordHash = _hashPassword(newPassword);

      // Update password in database
      final updatedUser = user.copyWith(passwordHash: newPasswordHash);
      await _databaseService.updateUser(updatedUser);

      return AuthResult(
        success: true,
        message: 'Password changed successfully',
        user: updatedUser,
      );
    } catch (e) {
      return AuthResult(
        success: false,
        message: 'Password change failed: ${e.toString()}',
      );
    }
  }

  /// Delete a user (user can only delete themselves)
  /// All associated data will be cascaded deleted
  Future<AuthResult> deleteUser({
    required String username,
    required String password,
  }) async {
    try {
      // Retrieve user
      final user = await _databaseService.getUser(username);

      if (user == null) {
        return AuthResult(
          success: false,
          message: 'User not found',
        );
      }

      // Verify password for security
      if (!_verifyPassword(password, user.passwordHash)) {
        return AuthResult(
          success: false,
          message: 'Password is incorrect. User not deleted.',
        );
      }

      // Delete user and all associated data
      await _databaseService.deleteUser(username);

      return AuthResult(
        success: true,
        message: 'User deleted successfully',
      );
    } catch (e) {
      return AuthResult(
        success: false,
        message: 'User deletion failed: ${e.toString()}',
      );
    }
  }

  /// Get all users (for user selection/switching)
  Future<List<User>> getAllUsers() async {
    return await _databaseService.getAllUsers();
  }

  /// Get a specific user
  Future<User?> getUser(String username) async {
    return await _databaseService.getUser(username);
  }
}

/// Result of validation
class ValidationResult {
  final bool isValid;
  final String message;

  ValidationResult({
    required this.isValid,
    this.message = '',
  });
}

/// Result of authentication operation
class AuthResult {
  final bool success;
  final String message;
  final User? user;

  AuthResult({
    required this.success,
    required this.message,
    this.user,
  });

  @override
  String toString() => 'AuthResult(success: $success, message: $message)';
}
