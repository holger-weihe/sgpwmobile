import 'package:flutter/material.dart';
import '../models/user.dart';
import '../services/user_auth_service.dart';
import '../services/database_service.dart';
import '../services/certificate_service.dart';
import '../services/configuration_manager.dart';
import '../services/biometric_auth_service.dart';
import 'change_password_screen.dart';

class AccountManagementScreen extends StatefulWidget {
  final String currentUsername;
  final VoidCallback onLogout;
  final Function(User)? onUserSwitched;

  const AccountManagementScreen({
    super.key,
    required this.currentUsername,
    required this.onLogout,
    this.onUserSwitched,
  });

  @override
  State<AccountManagementScreen> createState() =>
      _AccountManagementScreenState();
}

class _AccountManagementScreenState extends State<AccountManagementScreen> {
  late UserAuthService _userAuthService;
  late DatabaseService _databaseService;
  late CertificateService _certificateService;
  late ConfigurationManager _configManager;
  late BiometricAuthService _biometricAuthService;

  List<User> _users = [];
  User? _currentUser;
  bool _isLoading = true;
  String? _deleteConfirmUsername;
  bool _isDeleting = false;
  bool _isTogglingBiometric = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _loadUsers();
  }

  void _initializeServices() {
    _databaseService = DatabaseService();
    _userAuthService = UserAuthService(databaseService: _databaseService);
    _certificateService = CertificateService();
    _configManager = ConfigurationManager();
    _biometricAuthService = BiometricAuthService(databaseService: _databaseService);
  }

  Future<void> _loadUsers() async {
    try {
      // In per-user database architecture, only load current user's profile
      final currentUser = await _userAuthService.getUser(widget.currentUsername);
      
      if (currentUser == null) {
        // User not found in database, create a new user profile
        final newUser = User(
          username: widget.currentUsername,
          passwordHash: '',
          biometricEnabled: false,
          createdAt: DateTime.now(),
        );
        setState(() {
          _users = [newUser];
          _currentUser = newUser;
          _isLoading = false;
        });
        print('[ACCOUNT_MGMT] Created new user profile for ${widget.currentUsername}');
      } else {
        setState(() {
          _users = [currentUser];
          _currentUser = currentUser;
          _isLoading = false;
        });
        print('[ACCOUNT_MGMT] Loaded user profile for ${widget.currentUsername}');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load user: ${e.toString()}';
        _isLoading = false;
      });
      print('[ACCOUNT_MGMT] Error loading user: $e');
    }
  }

  Future<void> _CheckBiometricAvailability() async {
    try {
      final isAvailable = await _biometricAuthService.canUseBiometric();
      if (mounted) {
        print('Biometric available: $isAvailable');
      }
    } catch (e) {
      print('Error checking biometric: $e');
    }
  }

  Future<void> _toggleBiometric(bool enabled) async {
    if (_currentUser == null) return;

    setState(() {
      _isTogglingBiometric = true;
      _errorMessage = null;
    });

    try {
      if (enabled) {
        // Enroll biometric - this will prompt the user to verify their fingerprint
        final result = await _biometricAuthService.enrollBiometric(
          username: _currentUser!.username,
        );
        
        if (result.success) {
          setState(() {
            _currentUser = _currentUser!.copyWith(biometricEnabled: true);
            _isTogglingBiometric = false;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result.message),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 3),
              ),
            );
          }
        } else {
          // Even if verification failed, we can still enable biometric support
          setState(() {
            _errorMessage = result.message;
            _isTogglingBiometric = false;
          });
        }
      } else {
        // Disable biometric
        final updatedUser = _currentUser!.copyWith(
          biometricEnabled: false,
        );
        await _databaseService.updateUser(updatedUser);
        setState(() {
          _currentUser = updatedUser;
          _isTogglingBiometric = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Biometric authentication disabled'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to update biometric setting: $e';
        _isTogglingBiometric = false;
      });
    }
  }

  Future<void> _handleDeleteUser(String username, String password) async {
    setState(() {
      _isDeleting = true;
      _errorMessage = null;
    });

    try {
      // Require password confirmation for deletion
      final result = await _userAuthService.deleteUser(
        username: username,
        password: password,
      );

      if (result.success) {
        // Delete all user-specific data
        await _certificateService.deleteCertificates(username: username);
        await _configManager.deleteConfig(username: username);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('User deleted successfully')),
          );

          // Reload users list
          await _loadUsers();

          // If deleted current user, logout
          if (username == widget.currentUsername) {
            widget.onLogout();
          }

          setState(() {
            _deleteConfirmUsername = null;
          });
        }
      } else {
        setState(() {
          _errorMessage = result.message;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error deleting user: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  void _showDeleteConfirmDialog(User user) {
    final passwordController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Delete User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to delete user "${user.username}"?',
            ),
            const SizedBox(height: 16),
            const Text(
              'This action cannot be undone. All data associated with this user will be permanently deleted.',
              style: TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 16),
            if (user.username != widget.currentUsername)
              const Text(
                'Enter password to confirm:',
              ),
            if (user.username == widget.currentUsername)
              const Text(
                'You can only delete your own account. Enter your password to confirm this action.',
              ),
            const SizedBox(height: 8),
            TextField(
              controller: passwordController,
              decoration: InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _isDeleting ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: _isDeleting
                ? null
                : () {
                    Navigator.pop(context);
                    _handleDeleteUser(user.username, passwordController.text);
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: _isDeleting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account Management'),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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

                    // Current user section
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Current User',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.blue[50],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: TextField(
                                controller: TextEditingController(
                                  text: widget.currentUsername,
                                ),
                                readOnly: true,
                                decoration: InputDecoration(
                                  icon: const Icon(Icons.person),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Biometric toggle
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.fingerprint),
                                    const SizedBox(width: 12),
                                    const Text('Biometric Authentication'),
                                  ],
                                ),
                                Switch(
                                  value: _currentUser?.biometricEnabled ?? false,
                                  onChanged: _isTogglingBiometric
                                      ? null
                                      : (value) => _toggleBiometric(value),
                                  activeThumbColor: Colors.green,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        ChangePasswordScreen(
                                          username: widget.currentUsername,
                                          onPasswordChanged: () {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Password changed successfully',
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                  ),
                                );
                              },
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.vpn_key),
                                  SizedBox(width: 8),
                                  Text('Change Password'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // All users section
                    if (_users.isNotEmpty)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Registered Users',
                            style:
                                Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _users.length,
                            itemBuilder: (context, index) {
                              final user = _users[index];
                              final isCurrentUser =
                                  user.username ==
                                      widget.currentUsername;

                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                color: isCurrentUser
                                    ? Colors.blue[50]
                                    : null,
                                child: ListTile(
                                  leading: Icon(
                                    Icons.person,
                                    color: isCurrentUser
                                        ? Colors.blue
                                        : null,
                                  ),
                                  title: Text(
                                    user.username,
                                    style: TextStyle(
                                      fontWeight: isCurrentUser
                                          ? FontWeight.bold
                                          : null,
                                    ),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (user.lastLogin != null)
                                        Text(
                                          'Last login: ${user.lastLogin!.toString().split('.')[0]}',
                                        ),
                                      if (user.biometricEnabled)
                                        const Text(
                                          'Biometric: Enabled',
                                          style: TextStyle(
                                            color: Colors.green,
                                          ),
                                        ),
                                    ],
                                  ),
                                  trailing: PopupMenuButton<String>(
                                    onSelected: (value) {
                                      if (value ==
                                          'switch' &&
                                          !isCurrentUser) {
                                        widget.onUserSwitched
                                            ?.call(user);
                                      } else if (value ==
                                          'delete') {
                                        _showDeleteConfirmDialog(
                                          user,
                                        );
                                      }
                                    },
                                    itemBuilder:
                                        (BuildContext context) =>
                                            <PopupMenuEntry<String>>[
                                              if (!isCurrentUser)
                                                const PopupMenuItem<String>(
                                                  value: 'switch',
                                                  child: Row(
                                                    children: [
                                                      Icon(
                                                        Icons
                                                            .login,
                                                      ),
                                                      SizedBox(
                                                        width: 8,
                                                      ),
                                                      Text(
                                                        'Switch User',
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              PopupMenuItem<String>(
                                                value: 'delete',
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      Icons.delete,
                                                      color: Colors
                                                          .red,
                                                    ),
                                                    const SizedBox(
                                                      width: 8,
                                                    ),
                                                    Text(
                                                      isCurrentUser
                                                          ? 'Delete My Account'
                                                          : 'Delete User',
                                                      style: const TextStyle(
                                                        color:
                                                            Colors
                                                                .red,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}
