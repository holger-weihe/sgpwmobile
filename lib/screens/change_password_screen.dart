import 'package:flutter/material.dart';
import '../services/user_auth_service.dart';
import '../services/database_service.dart';

class ChangePasswordScreen extends StatefulWidget {
  final String username;
  final VoidCallback onPasswordChanged;

  const ChangePasswordScreen({
    super.key,
    required this.username,
    required this.onPasswordChanged,
  });

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  late UserAuthService _userAuthService;

  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _showOldPassword = false;
  bool _showNewPassword = false;
  bool _showConfirmPassword = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _initializeService();
  }

  void _initializeService() {
    final databaseService = DatabaseService();
    _userAuthService = UserAuthService(databaseService: databaseService);
  }

  Future<void> _handleChangePassword() async {
    // Validate inputs
    if (_oldPasswordController.text.isEmpty) {
      setState(() {
        _errorMessage = 'Current password is required';
        _successMessage = null;
      });
      return;
    }

    if (_newPasswordController.text.isEmpty) {
      setState(() {
        _errorMessage = 'New password is required';
        _successMessage = null;
      });
      return;
    }

    if (_newPasswordController.text != _confirmPasswordController.text) {
      setState(() {
        _errorMessage = 'New passwords do not match';
        _successMessage = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final result = await _userAuthService.changePassword(
        username: widget.username,
        oldPassword: _oldPasswordController.text,
        newPassword: _newPasswordController.text,
      );

      if (result.success) {
        setState(() {
          _successMessage = 'Password changed successfully';
          _oldPasswordController.clear();
          _newPasswordController.clear();
          _confirmPasswordController.clear();
        });

        // Notify parent and close after delay
        Future.delayed(const Duration(seconds: 1), () {
          widget.onPasswordChanged();
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      } else {
        setState(() {
          _errorMessage = result.message;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Change Password'),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),

              // Success message
              if (_successMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _successMessage!,
                    style: TextStyle(color: Colors.green[900]),
                  ),
                ),
              if (_successMessage != null) const SizedBox(height: 16),

              // Error message
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(color: Colors.red[900]),
                  ),
                ),
              if (_errorMessage != null) const SizedBox(height: 16),

              // Current password field
              TextField(
                controller: _oldPasswordController,
                decoration: InputDecoration(
                  labelText: 'Current Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showOldPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () {
                      setState(() {
                        _showOldPassword = !_showOldPassword;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                obscureText: !_showOldPassword,
                enabled: !_isLoading,
              ),
              const SizedBox(height: 24),

              // New password field
              TextField(
                controller: _newPasswordController,
                decoration: InputDecoration(
                  labelText: 'New Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showNewPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () {
                      setState(() {
                        _showNewPassword = !_showNewPassword;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                obscureText: !_showNewPassword,
                enabled: !_isLoading,
              ),
              const SizedBox(height: 16),

              // Confirm new password field
              TextField(
                controller: _confirmPasswordController,
                decoration: InputDecoration(
                  labelText: 'Confirm New Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showConfirmPassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () {
                      setState(() {
                        _showConfirmPassword = !_showConfirmPassword;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                obscureText: !_showConfirmPassword,
                enabled: !_isLoading,
              ),
              const SizedBox(height: 24),

              // Password requirements
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'New password must contain:\n'
                  '• At least 8 characters\n'
                  '• One uppercase letter\n'
                  '• One lowercase letter\n'
                  '• One number\n'
                  r'• One special character (!@#$%^&*)',
                  style: TextStyle(fontSize: 12, color: Colors.blue[900]),
                ),
              ),
              const SizedBox(height: 24),

              // Change password button
              ElevatedButton(
                onPressed: _isLoading ? null : _handleChangePassword,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Change Password'),
              ),
              const SizedBox(height: 16),

              // Cancel button
              OutlinedButton(
                onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
}
