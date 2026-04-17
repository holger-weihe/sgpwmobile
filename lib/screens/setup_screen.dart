import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import '../models/safeguard_config.dart';
import '../models/user.dart';
import '../models/auth_token.dart';
import '../services/certificate_service.dart';
import '../services/configuration_manager.dart';
import '../services/avatar_service.dart';
import '../services/safeguard_service.dart';

class SetupScreen extends StatefulWidget {
  final ConfigurationManager configManager;
  final VoidCallback onConfigSaved;
  final ValueChanged<AuthToken?>? onPasswordAuthToken; // Callback to pass token to parent
  final String? currentUsername;
  final User? currentUser;
  final ValueChanged<int>? onNavigateToScreen;
  final VoidCallback? onLogout;
  final SafeguardService? safeguardService;
  final bool isStandalone;

  const SetupScreen({
    super.key,
    required this.configManager,
    required this.onConfigSaved,
    this.onPasswordAuthToken,
    this.currentUsername,
    this.currentUser,
    this.onNavigateToScreen,
    this.onLogout,
    this.safeguardService,
    this.isStandalone = true,
  });

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _serverAddressController = TextEditingController();
  final _passwordLoginUsernameController = TextEditingController();
  final _passwordLoginPasswordController = TextEditingController();
  
  String? _certificateContent;
  String? _privateKeyContent;
  bool _isLoading = false;
  String? _errorMessage;
  String? _avatarBase64;
  late AvatarService _avatarService;
  Timer? _providerDebounceTimer;
  
  // Password login related
  List<Map<String, dynamic>> _authenticationProviders = [];
  String? _selectedAuthProvider;
  Map<String, dynamic>? _selectedProviderData;
  AuthToken? _currentAuthToken;

  @override
  void initState() {
    super.initState();
    _avatarService = AvatarService();
    
    if (widget.configManager.hasConfig) {
      final config = widget.configManager.config!;
      // Clean server address by removing https:// or http:// prefix if present
      String cleanedAddress = config.serverAddress;
      if (cleanedAddress.startsWith('https://')) {
        cleanedAddress = cleanedAddress.substring(8);
      } else if (cleanedAddress.startsWith('http://')) {
        cleanedAddress = cleanedAddress.substring(7);
      }
      _serverAddressController.text = cleanedAddress;
      
      // Load saved password authentication credentials
      if (config.authenticationProviderName != null) {
        _selectedAuthProvider = config.authenticationProviderName;
      }
      if (config.authenticationUsername != null) {
        _passwordLoginUsernameController.text = config.authenticationUsername!;
      }
      if (config.authenticationPassword != null) {
        _passwordLoginPasswordController.text = config.authenticationPassword!;
      }
    }
    
    // Listen for server address changes and reload providers
    _serverAddressController.addListener(() {
      print('[SETUP] Server address changed: ${_serverAddressController.text}');
      
      // Clean the address by removing https:// or http:// if user accidentally typed it
      final currentText = _serverAddressController.text;
      final cleanedAddress = _cleanServerAddress(currentText);
      if (cleanedAddress != currentText) {
        _serverAddressController.text = cleanedAddress;
        final newPosition = cleanedAddress.length;
        _serverAddressController.selection = TextSelection.fromPosition(
          TextPosition(offset: newPosition),
        );
      }
      
      // Debounce: cancel previous timer and start a new one
      _providerDebounceTimer?.cancel();
      _providerDebounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (_serverAddressController.text.isNotEmpty && !_isLoading) {
          print('[SETUP] Triggering provider load after debounce');
          _loadAuthenticationProviders();
        }
      });
    });
    
    _loadAvatar();
    _loadCertificatesAndKeys();
    _loadAuthenticationProviders();
  }

  @override
  void dispose() {
    _providerDebounceTimer?.cancel();
    _serverAddressController.dispose();
    _passwordLoginUsernameController.dispose();
    _passwordLoginPasswordController.dispose();
    super.dispose();
  }

  /// Clean server address by removing https:// or http:// prefix if present
  String _cleanServerAddress(String address) {
    if (address.startsWith('https://')) {
      return address.substring(8);
    } else if (address.startsWith('http://')) {
      return address.substring(7);
    }
    return address;
  }

  Future<void> _loadCertificatesAndKeys() async {
    if (widget.currentUsername == null) return;
    
    try {
      final certService = CertificateService();
      
      final cert = await certService.getCertificate(username: widget.currentUsername);
      final key = await certService.getPrivateKey(username: widget.currentUsername);
      
      if (mounted) {
        setState(() {
          _certificateContent = cert;
          _privateKeyContent = key;
        });
        print('Loaded certificate and key from storage for ${widget.currentUsername}');
      }
    } catch (e) {
      print('Error loading certificates: $e');
    }
  }



  Future<void> _loadAvatar() async {
    if (widget.currentUsername == null) return;
    final avatar = await _avatarService.getAvatar(widget.currentUsername!);
    if (mounted) {
      setState(() {
        _avatarBase64 = avatar;
      });
    }
  }



  Future<void> _pickAvatar() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);
      
      if (image != null && widget.currentUsername != null) {
        await _avatarService.saveAvatar(widget.currentUsername!, image.path);
        if (mounted) {
          final avatar = await _avatarService.getAvatar(widget.currentUsername!);
          setState(() {
            _avatarBase64 = avatar;
          });
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to upload avatar: $e')),
      );
    }
  }

  /// Get the current authentication token from password authentication
  AuthToken? getCurrentAuthToken() => _currentAuthToken;

  Future<void> _pickCertificate() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pem', 'crt', 'cer'],
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        final content = await File(file.path!).readAsString();

        if (!CertificateService.isValidPemCertificate(content)) {
          setState(() {
            _errorMessage = 'Invalid certificate format. Expected PEM format.';
          });
          return;
        }

        setState(() {
          _certificateContent = content;
          _errorMessage = null;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to read certificate: $e';
      });
    }
  }

  Future<void> _pickPrivateKey() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pem', 'key'],
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        final content = await File(file.path!).readAsString();

        if (!CertificateService.isValidPemPrivateKey(content)) {
          setState(() {
            _errorMessage = 'Invalid private key format. Expected PEM format.';
          });
          return;
        }

        setState(() {
          _privateKeyContent = content;
          _errorMessage = null;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to read private key: $e';
      });
    }
  }

  Future<void> _removeCertificates() async {
    try {
      final certificateService = CertificateService();
      await certificateService.deleteCertificates(username: widget.currentUsername);
      
      if (mounted) {
        setState(() {
          _certificateContent = null;
          _privateKeyContent = null;
          _errorMessage = null;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Certificates removed successfully'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to remove certificates: $e';
      });
    }
  }

  Future<void> _clearConfiguration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Clear Configuration?'),
        content: const Text(
          'This will remove all setup data including:\n'
          '• Safeguard Server Address\n'
          '• Certificates and Private Keys\n'
          '• Password Login Credentials\n\n'
          'Are you sure you want to continue?'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      setState(() => _isLoading = true);

      final certificateService = CertificateService();
      
      // Remove certificates
      await certificateService.deleteCertificates(username: widget.currentUsername);
      
      // Clear configuration
      await widget.configManager.deleteConfig(username: widget.currentUsername);

      if (mounted) {
        setState(() {
          _serverAddressController.clear();
          _certificateContent = null;
          _privateKeyContent = null;
          _passwordLoginUsernameController.clear();
          _passwordLoginPasswordController.clear();
          _selectedAuthProvider = null;
          _selectedProviderData = null;
          _currentAuthToken = null;
          // Clear the password auth token from SafeguardService too
          if (widget.safeguardService != null) {
            widget.safeguardService!.setPasswordAuthToken(null);
          }
          // Also clear from parent via callback
          if (widget.onPasswordAuthToken != null) {
            widget.onPasswordAuthToken!(null);
          }
          _errorMessage = null;
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Configuration cleared successfully'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to clear configuration: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveConfiguration() async {
    if (_serverAddressController.text.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a server address';
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      final certificateService = CertificateService();
      
      // Save certificate and key if provided (optional for browser auth fallback)
      if (_certificateContent != null && _privateKeyContent != null) {
        await certificateService.saveCertificateAndKey(
          certificate: _certificateContent!,
          privateKey: _privateKeyContent!,
          username: widget.currentUsername,
        );
      }

      // Save configuration with username and password authentication credentials
      final rstsProviderId = _selectedProviderData!['RstsProviderId'] as String? ?? _selectedAuthProvider;
      final config = SafeguardConfig(
        serverAddress: _serverAddressController.text.trim(),
        certificateKey: 'safeguard_certificate',
        privateKeyKey: 'safeguard_private_key',
        authenticationProviderName: _selectedAuthProvider,
        authenticationRstsProviderId: rstsProviderId,
        authenticationUsername: _passwordLoginUsernameController.text.isNotEmpty ? _passwordLoginUsernameController.text : null,
        authenticationPassword: _passwordLoginPasswordController.text.isNotEmpty ? _passwordLoginPasswordController.text : null,
      );

      await widget.configManager.saveConfig(config, username: widget.currentUsername);

      setState(() {
        _errorMessage = null;
        _isLoading = false;
      });

      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Configuration saved successfully!'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      widget.onConfigSaved();
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to save configuration: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadAuthenticationProviders() async {
    try {
      print('[PROVIDERS] Starting provider load...');
      // Start with default providers
      List<Map<String, dynamic>> providers = [
        {'Name': 'local', 'RstsProviderScope': 'rsts:sts:primaryproviderid:local'},
      ];

      // Try to load additional providers from the appliance if server address is available
      if (_serverAddressController.text.isNotEmpty) {
        try {
          final serverAddress = _serverAddressController.text.trim();
          final url = 'https://$serverAddress/service/core/v4/AuthenticationProviders?count=false&orderby=Name';
          print('[PROVIDERS] Making request to: $url');

          final httpClient = HttpClient();
          httpClient.badCertificateCallback = (cert, host, port) => true;

          final dio = Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
            validateStatus: (status) => status != null,
          ));
          
          dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => httpClient);

          print('[PROVIDERS] Sending GET request...');
          final response = await dio.get(url);
          print('[PROVIDERS] Response status code: ${response.statusCode}');
          print('[PROVIDERS] Response data type: ${response.data.runtimeType}');
          print('[PROVIDERS] Response data: ${response.data}');

          if (response.statusCode == 200) {
            dynamic data = response.data;
            List<Map<String, dynamic>> loadedProviders = [];
            
            // Handle OData response format with $values property
            if (data is List) {
              print('[PROVIDERS] Response is a List');
              loadedProviders = List<Map<String, dynamic>>.from(data);
            } else if (data is Map && data.containsKey('\$values')) {
              print('[PROVIDERS] Response is a Map with \$values property');
              loadedProviders = List<Map<String, dynamic>>.from(data['\$values']);
            } else if (data is Map) {
              print('[PROVIDERS] Response is a Map without \$values');
              loadedProviders = [Map<String, dynamic>.from(data)];
            } else {
              print('[PROVIDERS] Response is of unexpected type: ${data.runtimeType}');
            }
            
            print('[PROVIDERS] Parsed ${loadedProviders.length} providers');
            if (loadedProviders.isNotEmpty) {
              providers = loadedProviders;
              print('[PROVIDERS] ✓ Loaded ${providers.length} providers from appliance: ${providers.map((p) => p['Name']).toList()}');
            } else {
              print('[PROVIDERS] No providers parsed from response');
            }
          } else {
            print('[PROVIDERS] ✗ API returned status ${response.statusCode}: ${response.data}');
          }
        } catch (e, stackTrace) {
          print('[PROVIDERS] ✗ Failed to load from appliance: $e');
          print('[PROVIDERS] Stack trace: $stackTrace');
          // Continue with default providers
        }
      } else {
        print('[PROVIDERS] Server address is empty, using defaults');
      }
      
      if (mounted) {
        setState(() {
          _authenticationProviders = providers;
          print('[PROVIDERS] Updated UI with ${_authenticationProviders.length} providers');
          // Keep existing selection if it's still valid
          if (_selectedAuthProvider != null && !providers.any((p) => p['Name'] == _selectedAuthProvider)) {
            _selectedAuthProvider = null;
            _selectedProviderData = null;
          } else if (_selectedAuthProvider != null) {
            // Update the provider data for the selected provider
            _selectedProviderData = providers.firstWhere(
              (p) => p['Name'] == _selectedAuthProvider,
              orElse: () => {},
            );
          }
          _errorMessage = null;
        });
      }
    } catch (e) {
      print('[PROVIDERS] ✗ Unexpected error in _loadAuthenticationProviders: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load authentication providers: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _navigateToScreen(int screenIndex) async {
    // Save current config before navigating to allow viewing other screens
    if (_serverAddressController.text.isNotEmpty) {
      try {
        final config = SafeguardConfig(
          serverAddress: _serverAddressController.text.trim(),
          certificateKey: 'safeguard_certificate',
          privateKeyKey: 'safeguard_private_key',
        );
        await widget.configManager.saveConfig(config, username: widget.currentUsername);
      } catch (e) {
        // Silently fail - config save not critical for navigation
      }
    }
    
    widget.onNavigateToScreen?.call(screenIndex);
  }

  Future<void> _testConnection() async {
    if (_selectedAuthProvider == null || _selectedProviderData == null || _passwordLoginUsernameController.text.isEmpty || _passwordLoginPasswordController.text.isEmpty) {
      setState(() {
        _errorMessage = 'Please select a provider and enter username/password';
      });
      return;
    }

    if (_serverAddressController.text.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a server address';
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      final serverAddress = _serverAddressController.text.trim();
      final username = _passwordLoginUsernameController.text;
      final password = _passwordLoginPasswordController.text;
      final providerName = _selectedAuthProvider!;
      final rstsProviderId = _selectedProviderData!['RstsProviderId'] as String? ?? providerName;

      print('[SETUP] Testing connection with provider: $providerName (RstsProviderId: $rstsProviderId)');

      // Create SafeguardService and test password authentication
      final safeguardService = SafeguardService(
        serverAddress: serverAddress,
        certificateService: CertificateService(),
        username: username,
      );

      // Test authentication with provided credentials and RSTS provider ID
      final authToken = await safeguardService.authenticateWithPassword(
        providerName: providerName,
        rstsProviderId: rstsProviderId,
        username: username,
        password: password,
      );

      // Persist the API token in memory
      _currentAuthToken = authToken;
      print('[SETUP] ✓ API token persisted in memory for user: $username');
      
      // Pass the token to the main SafeguardService so it can be used by RequestScreen
      if (widget.safeguardService != null) {
        widget.safeguardService!.setPasswordAuthToken(authToken);
        print('[SETUP] ✓ Password auth token passed to SafeguardService for API requests');
      }
      
      // Also pass token back to parent (main.dart) via callback so it can be preserved after service recreation
      if (widget.onPasswordAuthToken != null) {
        widget.onPasswordAuthToken!(authToken);
        print('[SETUP] ✓ Password auth token passed to parent via callback');
      }

      setState(() {
        _errorMessage = null;
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Successfully authenticated as $username'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Test connection failed: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isStandalone) {
      // When used as part of main navigation, only render content without Scaffold
      return _buildContent();
    }
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safeguard Setup'),
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            tooltip: 'Menu',
            onSelected: (String value) {
              if (value == 'screen_0') {
                _navigateToScreen(0);
              } else if (value == 'screen_1') {
                _navigateToScreen(1);
              } else if (value == 'screen_2') {
                _navigateToScreen(2);
              } else if (value == 'screen_3') {
                _navigateToScreen(3);
              } else if (value == 'logout') {
                widget.onLogout?.call();
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
                      Icon(Icons.link, size: 20),
                      SizedBox(width: 12),
                      Text('Connection'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'screen_2',
                  child: Row(
                    children: [
                      Icon(Icons.vpn_key, size: 20),
                      SizedBox(width: 12),
                      Text('Password Vault'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'screen_3',
                  child: Row(
                    children: [
                      Icon(Icons.api, size: 20),
                      SizedBox(width: 12),
                      Text('API Request'),
                    ],
                  ),
                ),
              ];
            },
          ),
          // Avatar display
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: CircleAvatar(
              backgroundColor: Colors.grey[300],
              backgroundImage: _avatarBase64 != null && _avatarBase64!.isNotEmpty
                  ? MemoryImage(base64Decode(_avatarBase64!))
                  : null,
              child: _avatarBase64 == null || _avatarBase64!.isEmpty
                  ? const Icon(Icons.person, color: Colors.grey)
                  : null,
            ),
          ),
        ],
      ),
      body: _buildContent(),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const Text(
            'Safeguard Server Address',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _serverAddressController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: 'Enter server address (e.g., safeguard.example.com)',
              prefixIcon: const Icon(Icons.link),
              helperText: 'Note: Do not include https:// or http:// - the app will add it automatically',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 24),
          ExpansionTile(
            title: Row(
              children: [
                if (_certificateContent != null && _privateKeyContent != null)
                  Icon(Icons.check_circle, color: Colors.green.shade700, size: 20)
                else
                  Icon(Icons.info_outline, color: Colors.grey.shade700, size: 20),
                const SizedBox(width: 12),
                const Text(
                  'Certificate Login',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Certificate Upload',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Optional: PEM format certificate for PKCE authentication',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    if (_certificateContent != null)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          border: Border.all(color: Colors.green),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Colors.green),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Certificate loaded (${_certificateContent!.length} bytes)',
                                style: const TextStyle(color: Colors.green),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.info, color: Colors.grey),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'No certificate selected',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _pickCertificate,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Select Certificate'),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Private Key Upload',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Optional: PEM format private key for PKCE fallback',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    if (_privateKeyContent != null)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          border: Border.all(color: Colors.green),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Colors.green),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Private key loaded (${_privateKeyContent!.length} bytes)',
                                style: const TextStyle(color: Colors.green),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.info, color: Colors.grey),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'No private key selected',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _pickPrivateKey,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Select Private Key'),
                    ),
                    if (_certificateContent != null && _privateKeyContent != null) ...[
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _isLoading ? null : _removeCertificates,
                        icon: const Icon(Icons.delete, color: Colors.white),
                        label: const Text('Remove Certificates'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade600,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          ExpansionTile(
            title: Row(
              children: [
                if (_selectedAuthProvider != null && _passwordLoginUsernameController.text.isNotEmpty && _passwordLoginPasswordController.text.isNotEmpty)
                  Icon(Icons.check_circle, color: Colors.green.shade700, size: 20)
                else
                  Icon(Icons.info_outline, color: Colors.grey.shade700, size: 20),
                const SizedBox(width: 12),
                const Text(
                  'Password Login',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Authentication Provider',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_authenticationProviders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16.0),
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _loadAuthenticationProviders,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Load Providers'),
                        ),
                      )
                    else
                      DropdownButtonFormField<String>(
                        initialValue: _selectedAuthProvider,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'Select authentication provider',
                        ),
                        items: _authenticationProviders
                            .map((provider) => DropdownMenuItem<String>(
                              value: provider['Name'],
                              child: Text(provider['Name'] ?? 'Unknown'),
                            ))
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedAuthProvider = value;
                            _selectedProviderData = _authenticationProviders
                                .firstWhere((p) => p['Name'] == value, orElse: () => {});
                          });
                        },
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Username',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passwordLoginUsernameController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Enter your username',
                        prefixIcon: Icon(Icons.person),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Password',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passwordLoginPasswordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Enter your password',
                        prefixIcon: Icon(Icons.lock),
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _testConnection,
                      icon: _isLoading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white))) : const Icon(Icons.link),
                      label: const Text('Login'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _isLoading ? null : _saveConfiguration,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: Colors.blue,
            ),
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Text(
                    'Save Configuration',
                    style: TextStyle(fontSize: 16, color: Colors.white),
                  ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _isLoading ? null : _clearConfiguration,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: Colors.red,
            ),
            child: const Text(
              'Clear Configuration',
              style: TextStyle(fontSize: 16, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
