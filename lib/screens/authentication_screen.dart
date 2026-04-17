import 'package:flutter/material.dart';
import '../models/user.dart';
import '../services/user_auth_service.dart';
import '../services/biometric_auth_service.dart';
import '../services/database_service.dart';

class AuthenticationScreen extends StatefulWidget {
  final VoidCallback onLoginSuccess;
  final Function(User)? onUserSelected;

  const AuthenticationScreen({
    super.key,
    required this.onLoginSuccess,
    this.onUserSelected,
  });

  @override
  State<AuthenticationScreen> createState() => _AuthenticationScreenState();
}

class _AuthenticationScreenState extends State<AuthenticationScreen> {
  late UserAuthService _userAuthService;
  late BiometricAuthService _biometricAuthService;
  late DatabaseService _databaseService;

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _isLogin = true;
  bool _showPassword = false;
  bool _showConfirmPassword = false;
  String? _errorMessage;
  bool _canUseBiometric = false;
  List<User> _registeredUsers = [];

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _checkBiometric();
    _loadRegisteredUsers();
  }

  void _initializeServices() {
    _databaseService = DatabaseService();
    _userAuthService = UserAuthService(databaseService: _databaseService);
    _biometricAuthService = BiometricAuthService(databaseService: _databaseService);
  }

  Future<void> _checkBiometric() async {
    final canUse = await _biometricAuthService.canUseBiometric();
    setState(() {
      _canUseBiometric = canUse;
    });
  }

  Future<void> _loadRegisteredUsers() async {
    try {
      final users = await _userAuthService.getAllUsers();
      setState(() {
        _registeredUsers = users;
      });
    } catch (e) {
      print('Error loading users: $e');
    }
  }

  Future<void> _handleLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _userAuthService.login(
        username: _usernameController.text,
        password: _passwordController.text,
      );

      if (result.success && result.user != null) {
        if (mounted) {
          widget.onUserSelected?.call(result.user!);
          widget.onLoginSuccess();
        }
      } else {
        setState(() {
          _errorMessage = result.message;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Login error: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleBiometricLogin(String username) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _biometricAuthService.authenticateUser(
        username: username,
      );

      if (result.success && result.user != null) {
        if (mounted) {
          widget.onUserSelected?.call(result.user!);
          widget.onLoginSuccess();
        }
      } else {
        setState(() {
          _errorMessage = result.message;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Biometric auth error: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleRegister() async {
    // Validate passwords match
    if (_passwordController.text != _confirmPasswordController.text) {
      setState(() {
        _errorMessage = 'Passwords do not match';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _userAuthService.register(
        username: _usernameController.text,
        password: _passwordController.text,
      );

      if (result.success && result.user != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('User created successfully. Please login.')),
          );
          _usernameController.clear();
          _passwordController.clear();
          _confirmPasswordController.clear();
          setState(() {
            _isLogin = true;
          });
          _loadRegisteredUsers();
        }
      } else {
        setState(() {
          _errorMessage = result.message;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Registration error: ${e.toString()}';
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
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              const SizedBox(height: 24),
              Image.asset(
                'assets/images/splash.png',
                width: 120,
                height: 120,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 16),
              const Text(
                'Safeguard Mobile Passwords',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                _isLogin ? 'Login' : 'Create Account',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 32),

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

              // Username field
              TextField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: 'Username',
                  prefixIcon: const Icon(Icons.person),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                enabled: !_isLoading,
              ),
              const SizedBox(height: 16),

              // Password field
              TextField(
                controller: _passwordController,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () {
                      setState(() {
                        _showPassword = !_showPassword;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                obscureText: !_showPassword,
                enabled: !_isLoading,
              ),
              const SizedBox(height: 16),

              // Confirm password field (for register)
              if (!_isLogin)
                Column(
                  children: [
                    TextField(
                      controller: _confirmPasswordController,
                      decoration: InputDecoration(
                        labelText: 'Confirm Password',
                        prefixIcon: const Icon(Icons.lock),
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
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue[50],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Password must contain:\n'
                        '• At least 8 characters\n'
                        '• One uppercase letter\n'
                        '• One lowercase letter\n'
                        '• One number\n'
                        r'• One special character (!@#$%^&*)',
                        style: TextStyle(fontSize: 12, color: Colors.blue[900]),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),

              // Login/Register button
              ElevatedButton(
                onPressed: _isLoading
                    ? null
                    : (_isLogin ? _handleLogin : _handleRegister),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isLogin ? 'Login' : 'Create Account'),
              ),
              const SizedBox(height: 16),

              // Biometric button (if available and login mode)
              if (_canUseBiometric && _isLogin && _registeredUsers.isNotEmpty)
                OutlinedButton(
                  onPressed: _isLoading
                      ? null
                      : () => _handleBiometricLogin(_usernameController.text),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.fingerprint),
                      SizedBox(width: 8),
                      Text('Use Biometric'),
                    ],
                  ),
                ),
              if (_canUseBiometric && _isLogin && _registeredUsers.isNotEmpty)
                const SizedBox(height: 16),

              // Toggle between login/register
              Center(
                child: TextButton(
                  onPressed: _isLoading
                      ? null
                      : () {
                          setState(() {
                            _isLogin = !_isLogin;
                            _errorMessage = null;
                            _usernameController.clear();
                            _passwordController.clear();
                            _confirmPasswordController.clear();
                          });
                        },
                  child: Text(
                    _isLogin
                        ? "Don't have an account? Register"
                        : 'Already have an account? Login',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
}
