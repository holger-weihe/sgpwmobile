import 'package:flutter/material.dart';
import 'models/user.dart';
import 'models/auth_token.dart';
import 'services/configuration_manager.dart';
import 'services/safeguard_service.dart';
import 'services/certificate_service.dart';
import 'services/database_service.dart';
import 'services/data_encryption_service.dart';
import 'screens/authentication_screen.dart';
import 'screens/account_management_screen.dart';
import 'screens/setup_screen.dart';

import 'screens/account_passwords_screen.dart';
import 'screens/request_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Safeguard Mobile Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const AppNavigator(),
    );
  }
}

class AppNavigator extends StatefulWidget {
  const AppNavigator({super.key});

  @override
  State<AppNavigator> createState() => _AppNavigatorState();
}

class _AppNavigatorState extends State<AppNavigator> {
  // Authentication services
  late DatabaseService _databaseService;
  late ConfigurationManager _configManager;
  late CertificateService _certificateService;
  late DataEncryptionService _dataEncryptionService;

  // App services
  late SafeguardService _safeguardService;
  AuthToken? _currentPasswordAuthToken; // Store password token across service recreation

  // State
  User? _currentUser;
  bool _isInitialized = false;
  int _currentScreenIndex = 1; // Start at Password Vault (AccountPasswordsScreen)
  final GlobalKey<State<AccountPasswordsScreen>> _accountPasswordsKey = GlobalKey();

  final Map<int, String> _screenTitles = {
    0: 'Safeguard Setup',
    1: 'Connection',
    2: 'Password Vault',
    3: 'API Request',
  };

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Initialize all services
    _databaseService = DatabaseService();
    _certificateService = CertificateService();
    _dataEncryptionService = DataEncryptionService();
    _configManager = ConfigurationManager();

    // Listen to configuration changes (e.g., when config is cleared)
    _configManager.addListener(_onConfigurationChanged);

    // Database is ready, process complete
    setState(() {
      _isInitialized = true;
    });
  }

  void _onConfigurationChanged() {
    // Rebuild when configuration changes (e.g., config cleared)
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _configManager.removeListener(_onConfigurationChanged);
    super.dispose();
  }

  Future<void> _onLoginSuccess(User user) async {
    setState(() {
      _currentUser = user;
      _currentScreenIndex = 1; // Navigate to AccountPasswordsScreen
    });
    await _setupUserServices();
  }

  Future<void> _setupUserServices() async {
    if (_currentUser == null) return;

    // Load user's configuration
    await _configManager.loadConfig(username: _currentUser!.username);

    // Create SafeguardService with per-user parameters
    final config = _configManager.config;
    if (config != null) {
      _safeguardService = SafeguardService(
        serverAddress: config.serverAddress,
        certificateService: _certificateService,
        databaseService: _databaseService,
        dataEncryptionService: _dataEncryptionService,
        username: _currentUser!.username,
      );
      
      // Restore password auth token if it was set
      if (_currentPasswordAuthToken != null && !_currentPasswordAuthToken!.isExpired) {
        _safeguardService.setPasswordAuthToken(_currentPasswordAuthToken);
        print('[MAIN] Password auth token restored to new SafeguardService instance');
      }
    }
    
    // Rebuild UI after setup is complete
    if (mounted) {
      setState(() {});
    }
  }

  void _onPasswordAuthToken(AuthToken? token) {
    setState(() {
      _currentPasswordAuthToken = token;
      if (token != null) {
        print('[MAIN] Password auth token received from SetupScreen (expires: ${token.expiresAt})');
      } else {
        print('[MAIN] Password auth token cleared');
      }
    });
  }

  void _handleLogout() {
    // Close database for current user before clearing state
    if (_currentUser != null) {
      _databaseService.closeDatabase(_currentUser!.username);
      print('[MAIN] Database connection closed for user: ${_currentUser!.username}');
    }

    // Clear authentication tokens to prevent cross-contamination with next user
    _safeguardService.logout();
    print('[MAIN] Authentication tokens cleared for user: ${_currentUser?.username}');
  
    // CRITICAL: Clear stored password auth token so it's not restored for next user
    // Without this, next user gets old user's token
    _currentPasswordAuthToken = null;
    print('[MAIN] 🔑 Cleared stored password auth token to prevent token reuse');

    setState(() {
      _currentUser = null;
      _currentScreenIndex = 1; // Return to Password Vault on next login
    });
    _configManager.clearCurrentConfig();
  }

  Future<void> _handleUserSwitch(User newUser) async {
    _handleLogout();
    await _onLoginSuccess(newUser);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              SizedBox(
                width: 50,
                height: 50,
                child: CircularProgressIndicator(),
              ),
              SizedBox(height: 16),
              Text('Initializing app...'),
            ],
          ),
        ),
      );
    }

    // If not logged in, show authentication screen
    if (_currentUser == null) {
      return AuthenticationScreen(
        onLoginSuccess: () {
          // Callback when login is successful (no-op, state already updated in _onLoginSuccess)
        },
        onUserSelected: _onLoginSuccess,
      );
    }

    // Show main app screens
    if (!_configManager.hasConfig) {
      return SetupScreen(
        configManager: _configManager,
        onConfigSaved: () async {
          // Config saved, reload services
          await _setupUserServices();
        },
        onPasswordAuthToken: _onPasswordAuthToken,
        currentUsername: _currentUser?.username,
        onNavigateToScreen: (index) {
          setState(() {
            _currentScreenIndex = index;
          });
        },
        onLogout: _handleLogout,
      );
    }

    // Show main navigation
    return Scaffold(
      appBar: AppBar(
        title: Text(_screenTitles[_currentScreenIndex] ?? 'Safeguard Mobile Client'),
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            tooltip: 'Menu',
            onSelected: (String value) {
              if (value == 'screen_0') {
                setState(() => _currentScreenIndex = 0);
              } else if (value == 'screen_1') {
                setState(() => _currentScreenIndex = 1);
              } else if (value == 'screen_2') {
                setState(() => _currentScreenIndex = 2);
              } else if (value == 'account_management') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => AccountManagementScreen(
                      currentUsername: _currentUser!.username,
                      onLogout: _handleLogout,
                      onUserSwitched: _handleUserSwitch,
                    ),
                  ),
                );
              } else if (value == 'logout') {
                _handleLogout();
              }
            },
            itemBuilder: (BuildContext context) {
              return <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'screen_0',
                  child: Row(
                    children: [
                      Icon(Icons.settings, size: 20),
                      SizedBox(width: 12),
                      Text('Safeguard Setup'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'screen_1',
                  child: Row(
                    children: [
                      Icon(Icons.lock, size: 20),
                      SizedBox(width: 12),
                      Text('Password Vault'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'screen_2',
                  child: Row(
                    children: [
                      Icon(Icons.api, size: 20),
                      SizedBox(width: 12),
                      Text('API Request'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'account_management',
                  child: Row(
                    children: [
                      Icon(Icons.person, size: 20),
                      SizedBox(width: 12),
                      Text('Account Management'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'logout',
                  child: Row(
                    children: [
                      Icon(Icons.logout, size: 20, color: Colors.red),
                      SizedBox(width: 12),
                      Text('Logout', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ];
            },
          ),
          // Avatar display - centralized in AppBar
          if (_currentUser != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: CircleAvatar(
                backgroundColor: Colors.grey[300],
                child: const Icon(Icons.person, color: Colors.grey),
              ),
            ),
        ],
      ),
      body: IndexedStack(
        index: _currentScreenIndex,
        children: [
          SetupScreen(
            configManager: _configManager,
            onConfigSaved: () async {
              // Config saved, reload services
              await _setupUserServices();
            },
            onPasswordAuthToken: _onPasswordAuthToken,
            currentUsername: _currentUser?.username,
            safeguardService: _safeguardService,
            onNavigateToScreen: (index) {
              setState(() {
                _currentScreenIndex = index;
              });
            },
            onLogout: _handleLogout,
            isStandalone: false,
          ),
          AccountPasswordsScreen(
            key: _accountPasswordsKey,
            configManager: _configManager,
            safeguardService: _safeguardService,
            currentUsername: _currentUser?.username,
            onNavigateToScreen: (index) {
              setState(() {
                _currentScreenIndex = index;
              });
            },
            onLogout: _handleLogout,
            onPasswordAuthToken: _onPasswordAuthToken,
          ),
          RequestScreen(
            configManager: _configManager,
            safeguardService: _safeguardService,
          ),
        ],
      ),
    );
  }
}
