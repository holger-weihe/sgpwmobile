import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:collection/collection.dart';
import '../models/account_tree.dart';
import '../models/cached_account.dart';
import '../models/auth_token.dart';
import '../services/configuration_manager.dart';
import '../services/safeguard_service.dart';
import '../services/avatar_service.dart';
import '../services/database_service.dart';
import '../services/certificate_service.dart';
import '../services/browser_auth_service.dart';
import 'setup_screen.dart';

class AccountPasswordsScreen extends StatefulWidget {
  final ConfigurationManager configManager;
  final SafeguardService safeguardService;
  final Function(VoidCallback)? onScreenReady;
  final String? currentUsername;
  final ValueChanged<int>? onNavigateToScreen;
  final VoidCallback? onLogout;
  final Function(AuthToken?)? onPasswordAuthToken;

  const AccountPasswordsScreen({
    super.key,
    required this.configManager,
    required this.safeguardService,
    this.onScreenReady,
    this.currentUsername,
    this.onNavigateToScreen,
    this.onLogout,
    this.onPasswordAuthToken,
  });

  @override
  State<AccountPasswordsScreen> createState() => _AccountPasswordsScreenState();
}

class _AccountPasswordsScreenState extends State<AccountPasswordsScreen> {
  late SafeguardService _safeguardService;
  late DatabaseService _databaseService;
  late CertificateService _certificateService;
  
  bool _isLoading = false;
  bool _isOfflineMode = true;
  bool _isFetchingAllPasswords = false; // ← PREVENT concurrent password caching
  String? _errorMessage;
  String? _lastLoadedUsername; // Track which user's data is currently loaded
  AccountsDataResponse? _accountsData; // Current view data: DB in offline mode, API in online mode
  final Map<String, dynamic> _folders = {};
  final Map<String, bool> _expandedNodes = {};
  final Map<String, Map<String, dynamic>> _passwordCache = {};
  final Map<String, bool> _passwordVisibility =
      {}; // Track which passwords are shown
  final Map<String, Map<String, dynamic>> _accountsById =
      {}; // Accounts keyed by ID for fast lookup
  String? _avatarBase64;
  late AvatarService _avatarService;
  late TextEditingController _searchController;
  String _searchQuery = '';
  // Dual-view state
  bool _isListViewMode = false; // false = Tree View, true = Account List
  bool _accountListExpanded = false; // Account List section collapse state
  bool _treeViewExpanded = true; // Tree View section collapse state
  String _sortOrder = 'asc'; // Sort order for account list ('asc' or 'desc')
  final List<Map<String, dynamic>> _flatAccountList = []; // Cached flat account list

  @override
  void initState() {
    super.initState();
    _safeguardService = widget.safeguardService;
    _databaseService = DatabaseService();
    _certificateService = CertificateService();
    _avatarService = AvatarService();
    _searchController = TextEditingController();
    _searchController.addListener(_onSearchChanged);
    _loadAvatar();
    _initializeOfflineMode();
  }

  @override
  void didUpdateWidget(AccountPasswordsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If user switched, clear all in-memory cached data to prevent cross-contamination
    if (oldWidget.currentUsername != widget.currentUsername) {
      print('[USER_SWITCH] User changed from ${oldWidget.currentUsername} to ${widget.currentUsername}');
      print('[USER_SWITCH] Clearing in-memory state...');
      
      // Clear in-memory state (database clearing happens in _initializeOfflineMode)
      _accountsData = null;
      _folders.clear();
      _accountsById.clear();
      _passwordCache.clear();
      _passwordVisibility.clear();
      _expandedNodes.clear();
      _flatAccountList.clear();
      _searchController.clear();
      _searchQuery = '';
      _errorMessage = null;
      _isOfflineMode = true;
      _isListViewMode = false;
      _avatarBase64 = null;
      
      // Reload for new user
      _loadAvatar();
      _initializeOfflineMode();
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
    });
  }

  void _toggleViewMode() {
    setState(() {
      _isListViewMode = !_isListViewMode;
    });
  }

  void _toggleSortOrder(String newOrder) {
    setState(() {
      _sortOrder = newOrder;
    });
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
          final avatar = await _avatarService.getAvatar(
            widget.currentUsername!,
          );
          setState(() {
            _avatarBase64 = avatar;
          });
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to upload avatar: $e')));
    }
  }

  /// Perform authentication with certificate fallback to password
  /// Returns AuthToken on success, throws exception on failure
  Future<AuthToken> _performAuthenticationWithFallback() async {
    print('[AUTH_FALLBACK] Starting authentication with fallback logic...');
    
    // Step 1: Try certificate-based authentication first
    try {
      print('[AUTH_FALLBACK] Step 1: Attempting certificate-based authentication...');
      final token = await _safeguardService.authenticate();
      print('[AUTH_FALLBACK] ✅ Certificate-based auth successful');
      return token;
    } catch (certError) {
      print('[AUTH_FALLBACK] ⚠️ Certificate auth failed: $certError');
      
      // Step 2: Try password-based authentication with stored credentials
      final config = widget.configManager.config;
      if (config?.authenticationUsername != null && 
          config?.authenticationPassword != null && 
          config?.authenticationProviderName != null &&
          config?.authenticationRstsProviderId != null) {
        try {
          print('[AUTH_FALLBACK] Step 2: Attempting password-based authentication...');
          final token = await _safeguardService.authenticateWithPassword(
            providerName: config!.authenticationProviderName!,
            rstsProviderId: config.authenticationRstsProviderId!,
            username: config.authenticationUsername!,
            password: config.authenticationPassword!,
          );
          print('[AUTH_FALLBACK] ✅ Password-based auth successful');
          return token;
        } catch (passError) {
          print('[AUTH_FALLBACK] ⚠️ Password auth failed: $passError');
          throw Exception('Both certificate and password auth failed. Certificate: $certError, Password: $passError');
        }
      } else {
        print('[AUTH_FALLBACK] No stored credentials available for password auth');
        throw Exception('Certificate auth failed and no stored credentials for password auth. Certificate error: $certError');
      }
    }
  }

  /// Attempt automatic authentication if setup is complete
  /// Falls back to offline mode if authentication fails or is not configured
  Future<void> _attemptAutoAuthentication() async {
    if (widget.currentUsername == null) return;
    
    print('[AUTO_AUTH] Attempting automatic authentication...');
    AuthToken? token;
    
    try {
      token = await _performAuthenticationWithFallback();
    } catch (e) {
      print('[AUTO_AUTH] ⚠️ All authentication methods failed: $e');
      print('[AUTO_AUTH] Falling back to offline mode...');
    }
    
    // If authentication succeeded using either method
    if (token != null && mounted) {
      // Persist the API token in memory via the service
      _safeguardService.setPasswordAuthToken(token);
      print('[AUTO_AUTH] ✅ Password auth token persisted in SafeguardService');
      
      // Notify parent (main.dart) about the token so it can preserve it
      if (widget.onPasswordAuthToken != null) {
        widget.onPasswordAuthToken!(token);
        print('[AUTO_AUTH] ✅ Password auth token passed to parent via callback');
      }
      
      setState(() {
        _isOfflineMode = false;
      });
      // Update user preference to online mode
      final user = await _databaseService.getUser(widget.currentUsername!);
      if (user != null) {
        final updatedUser = user.copyWith(isOffline: false);
        await _databaseService.updateUser(updatedUser);
      }
      _loadAccountData();
    } else if (mounted) {
      // No token obtained, fall back to offline mode
      _loadAccountDataOffline();
    }
  }

  /// Initialize offline mode from stored user preference
  /// Attempts automatic authentication first if not explicitly set to offline
  Future<void> _initializeOfflineMode() async {
    if (widget.currentUsername == null) return;
    
    // CRITICAL: Clear stale offline data from PREVIOUS user when switching users
    // This prevents loading previous user's cached data (data contamination)
    if (_lastLoadedUsername != null && _lastLoadedUsername != widget.currentUsername) {
      print('[INIT] User changed: $_lastLoadedUsername → ${widget.currentUsername}, clearing stale cache for OLD user...');
      try {
        // Clear the OLD user's data, not the new user's data!
        await _databaseService.deleteCachedAccountsForUser(_lastLoadedUsername!);
        await _databaseService.deleteAccountTreeForUser(_lastLoadedUsername!);
        print('[INIT] ✅ Stale cache cleared for OLD user: $_lastLoadedUsername');
      } catch (e) {
        print('[INIT] ⚠️ Error clearing cache: $e');
      }
    }
    // Update tracking to current user for next switch
    _lastLoadedUsername = widget.currentUsername;
    
    try {
      final user = await _databaseService.getUser(widget.currentUsername!);
      if (user != null && mounted) {
        setState(() {
          _isOfflineMode = user.isOffline;
        });
        
        // Load data based on initial mode
        if (_isOfflineMode) {
          print('[INIT] User preference is offline mode');
          _loadAccountDataOffline();
        } else {
          print('[INIT] User preference is online mode, attempting auto-auth...');
          // User prefers online mode, attempt automatic authentication
          _attemptAutoAuthentication();
        }
      } else {
        print('[INIT] No user found, attempting auto-auth as first-time login...');
        // First time - attempt auto-auth
        _attemptAutoAuthentication();
      }
    } catch (e) {
      print('Error initializing offline mode: $e');
      // On error, fall back to offline
      if (mounted) {
        _loadAccountDataOffline();
      }
    }
  }

  /// Load account data from local database (offline mode)
  Future<void> _loadAccountDataOffline() async {
    if (widget.currentUsername == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final treeNodes = await _databaseService.getAccountTreeForUser(
        widget.currentUsername!,
      );
      print('[OFFLINE] Loaded ${treeNodes.length} tree nodes from database');

      // Load cached accounts from database
      var cachedAccounts = await _databaseService.getCachedAccountsForUser(
        widget.currentUsername!,
      );
      print(
        '[OFFLINE] Loaded ${cachedAccounts.length} cached accounts from database',
      );
      
      // If no cached accounts but we have online access, switch to online mode to sync
      if (cachedAccounts.isEmpty) {
        print('[OFFLINE] No cached accounts, attempting to load from API...');
        try {
          final accountsData = await _safeguardService.getAccountsData();
          if (accountsData.accounts.isNotEmpty) {
            print('[OFFLINE] Loaded ${accountsData.accounts.length} accounts from API');
            
            // CRITICAL: Persist all accounts to database for offline access
            if (widget.currentUsername != null) {
              final allAccountIds = <String>{};
              final cachedAccountsMap = <String, CachedAccount>{};
              
              // Add from flat accounts list
              for (final acc in accountsData.accounts) {
                if (acc is Map<String, dynamic>) {
                  try {
                    final ca = CachedAccount.fromApiData(
                      acc,
                      widget.currentUsername!,
                      accountsData.endpoint,
                    );
                    allAccountIds.add(ca.id);
                    cachedAccountsMap[ca.id] = ca;
                  } catch (e) {
                    print('[OFFLINE] Error creating CachedAccount: $e');
                  }
                }
              }
              
              // Add from tree structure
              if (accountsData.treeData?.containsKey('tree') ?? false) {
                _collectAccountsFromTreeForCaching(
                  accountsData.treeData!['tree'] as List,
                  cachedAccountsMap,
                  allAccountIds,
                  accountsData,
                );
              }
              
              final newCachedAccounts = cachedAccountsMap.values.toList();
              if (newCachedAccounts.isNotEmpty) {
                try {
                  await _databaseService.deleteCachedAccountsForUser(widget.currentUsername!);
                  await _databaseService.insertCachedAccounts(newCachedAccounts);
                  cachedAccounts = newCachedAccounts;
                  print('[OFFLINE] ✅ Persisted ${newCachedAccounts.length} accounts from API');
                } catch (e) {
                  print('[OFFLINE] Error persisting accounts: $e');
                }
              }
            }
          }
        } catch (apiError) {
          print('[OFFLINE] Failed to load from API: $apiError');
          throw Exception(
            'Offline cache is not yet initialized.\n\nTo use offline mode, first switch to online mode to sync and cache your passwords and account data.',
          );
        }
      }
      
      // Log what we loaded
      print('[OFFLINE] === LOADED ACCOUNTS DEBUG ===');
      for (final ca in cachedAccounts.take(3)) {
        print('[OFFLINE] Loaded account: id=${ca.id}, name=${ca.name}, url=${ca.url}, notes=${ca.notes}');
        print('[OFFLINE] Raw data keys: ${(ca.rawData).keys.toList()}');
        print('[OFFLINE] Raw data Url: ${ca.rawData['Url'] ?? ca.rawData['URL']}, Raw data Notes: ${ca.rawData['Notes']}');
      }

      // Populate in-memory accounts map from cached accounts
      _accountsById.clear();
      for (final cachedAccount in cachedAccounts) {
        // Merge rawData with explicit CachedAccount fields to ensure all data is available
        final accountData = Map<String, dynamic>.from(cachedAccount.rawData);
        
        // CRITICAL: Ensure 'Id' field is set for password cache lookup consistency
        if (!accountData.containsKey('Id')) {
          accountData['Id'] = cachedAccount.id;
          print('[OFFLINE_LOAD] Set accountData[\'Id\'] = ${cachedAccount.id} (from cachedAccount.id)');
        }
        
        // Ensure URL and Notes fields are present
        if (cachedAccount.url != null && accountData['Url'] == null && accountData['URL'] == null) {
          accountData['Url'] = cachedAccount.url;
        }
        if (cachedAccount.notes != null && accountData['Notes'] == null) {
          accountData['Notes'] = cachedAccount.notes;
        }
        
        // Log date fields for debugging
        print('[OFFLINE_LOAD] Account ${cachedAccount.id} dates: CreatedDate=${accountData['CreatedDate']}, ExpirationDate=${accountData['ExpirationDate']}');
        
        _accountsById[cachedAccount.id] = accountData;
        print('[OFFLINE_LOAD] Added account ${cachedAccount.id}: name=${cachedAccount.name}, url=${cachedAccount.url}, notes=${cachedAccount.notes}');
      }

      if (treeNodes.isEmpty && cachedAccounts.isEmpty) {
        throw Exception(
          'Offline cache is not yet initialized.\n\nTo use offline mode, first switch to online mode to sync and cache your passwords and account data.',
        );
      }

      // Pre-load passwords from database for offline mode
      print('[OFFLINE] Pre-loading cached passwords from database');
      _passwordCache.clear();
      for (final cachedAccount in cachedAccounts) {
        final accountId = cachedAccount.id.toString(); // Ensure string representation
        
        // Try to retrieve cached password (already decrypted by service)
        final password = await _safeguardService.getCachedPassword(
          accountId: accountId,
          usernameParam: widget.currentUsername,
          isOfflineMode: true,
        );
        
        if (password != null) {
          if (password.startsWith('ACCOUNT_EXPIRED:')) {
            print('[OFFLINE] Loaded EXPIRED account for: $accountId - but password is included, caching it');
            _passwordCache[accountId] = {'Password': password};
          } else {
            print('[OFFLINE] Loaded cached password for account: $accountId');
            _passwordCache[accountId] = {'Password': password};
          }
        } else {
          print('[OFFLINE] No cached password for account: $accountId');
          _passwordCache[accountId] = {'status': 'offline'};
        }
      }
      print('[OFFLINE] Pre-loaded ${_passwordCache.length} passwords into cache');
      print('[OFFLINE] Password cache keys: ${_passwordCache.keys.toList()}');
      print('[OFFLINE] _accountsById keys: ${_accountsById.keys.toList()}');
      for (final entry in _passwordCache.entries.take(5)) {
        print('[OFFLINE] Cache[${entry.key}] = ${entry.value}');
      }

      setState(() {
        // Don't clear _accountsData - keep it for offline account display
        _folders.clear();
        _expandedNodes.clear();
        _expandedNodes['root'] = true;

        print('[OFFLINE_DB_DUMP] ====== COMPLETE DATABASE STATE ======');
        print('[OFFLINE_DB_DUMP] Total nodes loaded: ${treeNodes.length}');
        if (treeNodes.isNotEmpty) {
          print('[OFFLINE_DB_DUMP] -- ALL NODES --');
          for (int i = 0; i < treeNodes.length; i++) {
            final node = treeNodes[i];
            final type = node.isFolder ? 'FOLDER' : 'ACCOUNT';
            final parentStr = node.parentId != null ? ', parent=${node.parentId}' : ', parent=null';
            final acctStr = node.accountId != null ? ', account=${node.accountId}' : '';
            print('[OFFLINE_DB_DUMP] [$i] $type: id=${node.id}, name="${node.name}"$parentStr$acctStr, depth=${node.depth}, sequenceOrder=${node.sequenceOrder}');
          }
        } else {
          print('[OFFLINE_DB_DUMP] ⚠️ NO NODES LOADED FROM DATABASE!');
        }
        print('[OFFLINE_DB_DUMP] ====== END DATABASE DUMP ======');

        // Build tree structure from AccountTree nodes
        _buildTreeFromNodes(treeNodes);
        print('[OFFLINE] Built ${_folders.length} folders from tree nodes');
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  /// Build tree structure from database nodes
  void _buildTreeFromNodes(List<AccountTree> nodes, {Map<String, String> freshAccountNames = const {}}) {
    _folders.clear();
    print('[TREE_BUILD] === BUILDING TREE WITH ${nodes.length} NODES ===');
    
    // Log all nodes being loaded from database (for debugging folder structure)
    for (final node in nodes) {
      final nodeType = node.isFolder ? 'FOLDER' : 'ACCOUNT';
      final acctId = node.accountId != null ? ', accountId=${node.accountId}' : '';
      print('[TREE_BUILD] [DB_NODE] $nodeType: id=${node.id}, name=${node.name}, parentId=${node.parentId}$acctId');
    }
    
    for (final node in nodes) {
      // Use fresh account name if available for this account
      String displayName = node.name;
      if (node.accountId != null) {
        final freshName = freshAccountNames[node.accountId.toString()];
        if (freshName != null) {
          print('[TREE_BUILD] Using fresh name for account ${node.accountId}: $displayName -> $freshName');
          displayName = freshName;
        }
      }
      
      // Merge cached account data into tree node data for offline display
      var mergedAccountData = Map<String, dynamic>.from(node.accountData ?? {});
      if (node.accountId != null && _accountsById.containsKey(node.accountId!)) {
        final cachedData = _accountsById[node.accountId]!;
        print('[TREE_BUILD] BEFORE MERGE - Node ${node.accountId}: accountData.keys=${mergedAccountData.keys.toList()}, cachedData.keys=${cachedData.keys.toList()}');
        print('[TREE_BUILD]   accountData has Url=${mergedAccountData['Url']}, Notes=${mergedAccountData['Notes']}');
        print('[TREE_BUILD]   cachedData has Url=${cachedData['Url']}, Notes=${cachedData['Notes']}');
        
        // Merge cached data, but don't override existing node data
        for (final entry in cachedData.entries) {
          if (!mergedAccountData.containsKey(entry.key)) {
            mergedAccountData[entry.key] = entry.value;
          }
        }
        
        print('[TREE_BUILD] AFTER MERGE - Node ${node.accountId}: keys=${mergedAccountData.keys.toList()}, Url=${mergedAccountData['Url']}, Notes=${mergedAccountData['Notes']}');
      }
      
      _folders[node.id.toString()] = {
        'name': displayName,
        'isFolder': node.isFolder,
        'parentId': node.parentId,
        'accountId': node.accountId,
        'id': node.id.toString(),
        // Store merged account data with all fields including Notes
        'accountData': mergedAccountData,
      };
      
      if (!node.isFolder && node.accountId != null) {
        print('[TREE_BUILD] Stored account node: id=${node.id}, accountId=${node.accountId}, url=${mergedAccountData['Url']}, notes=${mergedAccountData['Notes']}');
      }
    }
    
    // Debug: Print the entire offline data map
    print('[OFFLINE_DEBUG] Built _folders map with ${_folders.length} nodes:');
    for (final entry in _folders.entries) {
      final node = entry.value;
      final accountData = node['accountData'] as Map;
      print('[OFFLINE_DEBUG]   Node ID=${entry.key}: name=${node['name']}, isFolder=${node['isFolder']}, accountId=${node['accountId']}, Url=${accountData['Url']}, Notes=${accountData['Notes']}');
    }
    
    // CRITICAL: Add any accounts from _accountsById that aren't in the tree (offline display)
    final accountIdsInTree = _folders.values
        .where((n) => n['accountId'] != null)
        .map((n) => n['accountId'].toString())
        .toSet();
    
    int maxNodeId = nodes.isNotEmpty ? nodes.map((n) => n.id).reduce((a, b) => a > b ? a : b) : 0;
    int nextNodeId = maxNodeId + 1;
    
    for (final entry in _accountsById.entries) {
      final accountId = entry.key;
      if (!accountIdsInTree.contains(accountId)) {
        print('[TREE_BUILD] Adding account not in tree: id=$accountId, name=${entry.value['Name']}');
        
        // Find root folder to attach this account
        String? rootFolderId;
        for (final folderEntry in _folders.entries) {
          if (folderEntry.value['isFolder'] == true && folderEntry.value['parentId'] == null) {
            rootFolderId = folderEntry.key;
            break;
          }
        }
        
        if (rootFolderId != null) {
          _folders[nextNodeId.toString()] = {
            'name': entry.value['Name'] ?? entry.value['AccountName'] ?? 'Unknown',
            'isFolder': false,
            'parentId': rootFolderId,
            'accountId': accountId,
            'id': nextNodeId.toString(),
            'accountData': entry.value,
          };
          print('[TREE_BUILD] ✓ Added missing account to offline tree: $accountId');
          nextNodeId++;
        }
      }
    }
  }

  /// Toggle between offline and online modes
  Future<void> _toggleOfflineMode(bool offline) async {
    if (widget.currentUsername == null) return;

    // If switching to offline, load the synced offline data if available
    if (offline && !_isOfflineMode) {
      // CRITICAL: Save fresh online data BEFORE clearing it
      final freshAccountsData = _accountsData;
      final freshAccountsById = Map<String, Map<String, dynamic>>.from(_accountsById);
      
      setState(() {
        _isOfflineMode = true;
        _isLoading = true;
        _errorMessage = null;
        // Clear all online data when switching to offline
        _accountsData = null; // Clear online tree data
        _accountsById.clear(); // Clear old account cache
        _passwordCache.clear(); // Will be repopulated with offline passwords
      });

      try {
        // Try to load offline data first
        final treeNodes = await _databaseService.getAccountTreeForUser(
          widget.currentUsername!,
        );

        if (treeNodes.isEmpty) {
          // No offline data - if we have fresh online data, use it; otherwise sync from server
          if (freshAccountsData != null) {
            print('[OFFLINE] No cached offline data but have fresh online data - persisting it now');
            await _syncToOfflineMode(freshAccountsData, freshAccountsById);
          } else {
            print('[OFFLINE] No offline data and no fresh online data - running full sync workflow');
            await _syncToOfflineMode();
          }
          return;
        }

        // Load cached accounts from database
        final cachedAccounts = await _databaseService.getCachedAccountsForUser(
          widget.currentUsername!,
        );
        print(
          '[OFFLINE] Loaded ${cachedAccounts.length} cached accounts from database',
        );
        
        // Log what we loaded from the database BEFORE merging with fresh data
        for (final ca in cachedAccounts) {
          final rawName = ca.rawData['Name'] ?? 'N/A';
          print('[OFFLINE] [DB_LOAD] id=${ca.id}, cachedName=${ca.name}, rawDataName=$rawName, url=${ca.url}, notes=${ca.notes}');
        }

        // Build a map of fresh account data from online data if available
        final freshAccountData = <String, Map<String, dynamic>>{};
        if (freshAccountsData != null && freshAccountsData.accounts.isNotEmpty) {
          print('[OFFLINE] Building fresh account data map from online data');
          for (final account in freshAccountsData.accounts) {
            if (account is Map<String, dynamic>) {
              final id = account['Id']?.toString();
              if (id != null) {
                freshAccountData[id] = Map<String, dynamic>.from(account);
                print('[OFFLINE] Fresh data for ID $id: Name=${account['Name']}, Url=${account['Url']}, Notes=${account['Notes']}');
              }
            }
          }
        }

        // Populate in-memory accounts map from cached accounts, using fresh data when available
        _accountsById.clear();
        for (final cachedAccount in cachedAccounts) {
          final accountData = Map<String, dynamic>.from(cachedAccount.rawData);
          final accountId = cachedAccount.id.toString();
          
          // CRITICAL: Ensure 'Id' field is set for cache lookups
          if (!accountData.containsKey('Id')) {
            accountData['Id'] = accountId;
            print('[OFFLINE] Set accountData[\'Id\'] = $accountId (from cachedAccount.id)');
          }
          
          // PRIORITY 1: Get fresh data from online session if available
          if (freshAccountData.containsKey(accountId)) {
            final freshData = freshAccountData[accountId]!;
            // Restore Name, URL and Notes from fresh online data
            if (freshData['Name'] != null) {
              accountData['Name'] = freshData['Name'];
              print('[OFFLINE] Restored Name from fresh data: $accountId -> ${freshData['Name']}');
            }
            if (freshData['Url'] != null) {
              accountData['Url'] = freshData['Url'];
              print('[OFFLINE] Restored Url from fresh data: $accountId -> ${freshData['Url']}');
            }
            if (freshData['Notes'] != null) {
              accountData['Notes'] = freshData['Notes'];
              print('[OFFLINE] Restored Notes from fresh data: $accountId -> ${freshData['Notes']}');
            }
          }
          
          // PRIORITY 2: Ensure fields are present from explicit CachedAccount properties (fallback)
          if (cachedAccount.url != null && (accountData['Url'] == null || accountData['Url'] == '')) {
            accountData['Url'] = cachedAccount.url;
            print('[OFFLINE] Added Url from CachedAccount: ${cachedAccount.id} -> ${cachedAccount.url}');
          }
          if (cachedAccount.notes != null && (accountData['Notes'] == null || accountData['Notes'] == '')) {
            accountData['Notes'] = cachedAccount.notes;
            print('[OFFLINE] Added Notes from CachedAccount: ${cachedAccount.id} -> ${cachedAccount.notes}');
          }
          
          _accountsById[cachedAccount.id] = accountData;
          print(
            '[OFFLINE] Cached account: id=${cachedAccount.id}, name=${accountData['Name'] ?? cachedAccount.name}, url=${accountData['Url']}, notes=${accountData['Notes']}',
          );
        }

        // Pre-load cached passwords from database for offline mode
        print('[OFFLINE] Loading cached passwords from database...');
        print('[OFFLINE] Using username: ${widget.currentUsername}');
        _passwordCache.clear();
        for (final cachedAccount in cachedAccounts) {
          final accountId = cachedAccount.id.toString(); // ← Ensure string representation
          
          // Try to retrieve cached password (already decrypted by service)
          print('[OFFLINE] Attempting to load password for accountId=$accountId (type=${cachedAccount.id.runtimeType}), username=${widget.currentUsername}');
          final password = await _safeguardService.getCachedPassword(
            accountId: accountId,
            usernameParam: widget.currentUsername,
            isOfflineMode: true,
          );
          
          if (password != null && password.isNotEmpty) {
            print('[OFFLINE] ✅ SUCCESS: Loaded cached password for account: $accountId (length=${password.length})');
            _passwordCache[accountId] = {'Password': password};
          } else {
            print('[OFFLINE] ❌ FAILED: No cached password found for account: $accountId (null=${password == null}, empty=${password?.isEmpty})');
            // Mark as offline - indicates we don't have a cached password
            _passwordCache[accountId] = {'status': 'offline'};
          }
        }
        print('[OFFLINE] Pre-loaded offline mode: ${_passwordCache.length} accounts processed, ${_passwordCache.values.where((v) => v.containsKey("Password")).length} with passwords'); 
        print('[OFFLINE] Password cache keys: ${_passwordCache.keys.toList()}');
        print('[OFFLINE] Password cache status: ${_passwordCache.entries.map((e) => "${e.key}:${e.value.keys.toList()}").toList()}');

        // DIAGNOSTIC: Dump database state before switching to offline
        if (_safeguardService.databaseService != null && widget.currentUsername != null) {
          await _safeguardService.databaseService!.diagnosticDump(widget.currentUsername!);
        }

        // Load and display offline data
        if (mounted) {
          setState(() {
            // In offline mode, set _accountsData to loaded persisted data
            _accountsData = AccountsDataResponse(
              accounts: cachedAccounts.map((ca) => ca.rawData).toList(),
              endpoint: '', // Not available in offline mode
              folderName: 'Offline', 
              treeData: {},
            );
            _folders.clear();
            _expandedNodes.clear();
            _expandedNodes['root'] = true;
            _buildTreeFromNodes(treeNodes);
            _isLoading = false;
          });
        }

        // Update user's offline preference
        final user = await _databaseService.getUser(widget.currentUsername!);
        if (user != null) {
          final updatedUser = user.copyWith(isOffline: true);
          await _databaseService.updateUser(updatedUser);
        }

        // CRITICAL: Persist the freshly merged account data back to the database
        // This ensures that when the user logs out and logs back in, they get the latest data
        if (widget.currentUsername != null && _accountsById.isNotEmpty) {
          print('[OFFLINE] === PERSISTING MERGED FRESH DATA BACK TO DATABASE ===');
          final mergedCachedAccounts = <CachedAccount>[];
          for (final entry in _accountsById.entries) {
            final accountId = entry.key.toString();
            final accountData = entry.value;
            final name = accountData['Name'] ?? 'Unknown';
            final url = accountData['Url']?.toString();
            final notes = accountData['Notes']?.toString();
            final createdDate = accountData['CreatedDate']?.toString();
            final expirationDate = accountData['ExpirationDate']?.toString();
            
            final merged = CachedAccount(
              id: accountId,
              username: widget.currentUsername!,
              name: name.toString(),
              accountName: accountData['AccountName']?.toString(),
              url: url,
              notes: notes,
              hasPassword: accountData['HasPassword'] ?? false,
              endpoint: accountData['endpoint'] ?? '',
              cachedAt: DateTime.now(),
              rawData: accountData,
            );
            mergedCachedAccounts.add(merged);
            final notesPreview = notes != null ? (notes.length > 50 ? '${notes.substring(0, 50)}...' : notes) : "null";
            print('[OFFLINE] [PERSIST] Merged account: id=$accountId, name=$name, url=$url, notes=$notesPreview, createdDate=$createdDate, expirationDate=$expirationDate');
          }
          
          // Update database with the merged fresh data
          await _databaseService.deleteCachedAccountsForUser(widget.currentUsername!);
          await _databaseService.insertCachedAccounts(mergedCachedAccounts);
          print('[OFFLINE] [PERSIST] ✅ Updated database with ${mergedCachedAccounts.length} merged fresh accounts');
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Switched to offline mode')),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Error switching to offline: $e';
            _isOfflineMode = false; // Revert
            _isLoading = false;
            // Restore online data if available
            if (freshAccountsData != null) {
              _accountsData = freshAccountsData;
              _accountsById.addAll(freshAccountsById);
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to switch to offline: $e')),
          );
        }
      }
      return;
    }

    // If switching to online, authenticate first then load from server
    if (!offline && _isOfflineMode) {
      setState(() {
        _isOfflineMode = false;
        _isLoading = true;
        _errorMessage = null;
        // Clear all offline data to ensure we render fresh online data
        _folders.clear();
        _accountsById.clear(); // ← CRITICAL: Clear old cached account data
      });

      try {
        print('[MODE_SWITCH] Attempting to load account data online...');
        
        // Try to load account data first  
        // If we get an error, try to re-authenticate and load again
        AccountsDataResponse? accountsData;
        
        try {
          accountsData = await _safeguardService.getAccountsData();
          print('[MODE_SWITCH] ✓ Successfully loaded account data with existing token');
        } catch (loadError) {
          print('[MODE_SWITCH] First load attempt failed: $loadError');
          print('[MODE_SWITCH] Attempting to re-authenticate with fallback...');
          
          try {
            final token = await _performAuthenticationWithFallback();
            _safeguardService.setPasswordAuthToken(token);
            // Notify parent about token
            if (widget.onPasswordAuthToken != null) {
              widget.onPasswordAuthToken!(token);
            }
            print('[MODE_SWITCH] ✓ Re-authenticated successfully');
            
            accountsData = await _safeguardService.getAccountsData();
            print('[MODE_SWITCH] ✓ Successfully loaded account data after re-auth');
          } catch (authError) {
            print('[MODE_SWITCH] ✗ Re-authentication failed: $authError');
            rethrow;
          }
        }

        if (mounted) {
          // Clear old offline password cache - need fresh passwords in online mode
          _passwordCache.clear();
          
          // Populate account lookup map for fast online access (with cleared _accountsById)
          // This handles both empty and non-empty accounts lists
          if (accountsData.accounts.isNotEmpty) {
            _populateAccountsMap(accountsData.accounts, accountsData.endpoint, treeData: accountsData.treeData);
          }
          
          setState(() {
            _accountsData = accountsData;
            _isLoading = false;
            _expandedNodes.clear(); // Clear old expansion state
            _expandedNodes['root'] = true;
          });
          
          // Only proceed with password fetching if there are accounts
          if (accountsData.accounts.isNotEmpty) {
            // Eagerly fetch all passwords after setting state
            print('[MODE_SWITCH] Waiting for all passwords to be fetched and cached...');
            await _fetchAllPasswordsEagerly();
            print('[MODE_SWITCH] All passwords fetched and cached, online mode ready');
          } else {
            print('[MODE_SWITCH] ℹ️  No accounts in online vault - online mode ready with empty account list');
          }
          
          // CRITICAL: Persist accounts to database for offline access
          print('[MODE_SWITCH] Persisting all accounts to database for offline access...');
          if (widget.currentUsername != null) {
            // IMPORTANT: Clear ALL offline data first (tree + accounts + passwords)
            // This ensures complete replacement of offline data with online data
            print('[MODE_SWITCH] 🗑️  Clearing all existing offline data for ${widget.currentUsername}...');
            try {
              await _databaseService.deleteAccountTreeForUser(widget.currentUsername!);
              print('[MODE_SWITCH] ✓ Deleted tree nodes for user');
              await _databaseService.deleteCachedAccountsForUser(widget.currentUsername!);
              print('[MODE_SWITCH] ✓ Deleted cached accounts for user');
              await _databaseService.deleteCachedPasswordsForUser(widget.currentUsername!);
              print('[MODE_SWITCH] ✓ Deleted cached passwords for user');
            } catch (e) {
              print('[MODE_SWITCH] ⚠️  Error clearing offline data: $e');
            }
            
            // Build and persist fresh tree and account structure from online data
            // This replaces the cleared offline data with current online data
            print('[MODE_SWITCH] 🔄 Rebuilding offline tree and account structure from online data...');
            try {
              await _convertAndPersistAccountTree(accountsData);
              print('[MODE_SWITCH] ✅ Successfully rebuilt and persisted offline tree structure from online data');
            } catch (e) {
              print('[MODE_SWITCH] ⚠️  Error persisting tree structure: $e');
            }
          } else {
            print('[MODE_SWITCH] ℹ️  No user specified, skipping offline persistence');
          }
        }

        // Update user's offline preference
        final user = await _databaseService.getUser(widget.currentUsername!);
        if (user != null) {
          final updatedUser = user.copyWith(isOffline: false);
          await _databaseService.updateUser(updatedUser);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Switched to online mode')),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Error switching to online: $e';
            _isOfflineMode = true; // Revert to offline on error
            _isLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to switch to online: $e')),
          );
        }
      }
    }
  }

  /// Check if browser auth, certificate, key, and server address are available
  Future<bool> _checkPrerequisites() async {
    try {
      final config = widget.configManager.config;
      
      // Check if server address is configured
      if (config?.serverAddress == null || config!.serverAddress.isEmpty) {
        return false;
      }
      
      // PRIMARY: Check for browser authentication with rSTS token (new method)
      final browserAuthService = BrowserAuthService();
      final browserAuth = await browserAuthService.getSavedAuthData();
      if (browserAuth != null && browserAuth.isValid && !browserAuth.isExpired) {
        print('[PREREQ] Browser auth available: ${browserAuth.method}');
        
        // If we have an rSTS token, that's sufficient (no certificates needed)
        if (browserAuth.method == 'webview_rsts_token' && browserAuth.token != null && browserAuth.token!.isNotEmpty) {
          print('[PREREQ] ✅ rSTS token available - no certificates needed');
          return true;
        }
        
        // If it's just a WebView session marker, we need certificates as fallback
        if (browserAuth.method == 'webview_session') {
          print('[PREREQ] ⚠️ WebView session detected - checking if certificates available as fallback');
          final cert = await _certificateService.getCertificate();
          final key = await _certificateService.getPrivateKey();
          if (cert == null || cert.isEmpty || key == null || key.isEmpty) {
            print('[PREREQ] ✗ WebView session alone insufficient - need certificates');
            return false;
          }
        }
        return true;
      }
      
      // FALLBACK: Check for certificates
      final cert = await _certificateService.getCertificate();
      final key = await _certificateService.getPrivateKey();
      
      return cert != null &&
          cert.isNotEmpty &&
          key != null &&
          key.isNotEmpty;
    } catch (e) {
      print('Error checking prerequisites: $e');
      return false;
    }
  }

  /// Show SetupScreen as an overlay dialog
  Future<void> _showSetupScreenOverlay() async {
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => Dialog(
        child: SetupScreen(
          configManager: widget.configManager,
          onConfigSaved: () {
            Navigator.of(dialogContext).pop();
          },
          currentUsername: widget.currentUsername,
        ),
      ),
    );
  }

  /// Authenticate to Safeguard API using browser auth (OAuth2 rSTS token), certificates, or password
  Future<bool> _authenticateToSafeguardAPI() async {
    try {
      print('[AUTH] Attempting authentication...');
      // Try certificate auth first, then fall back to password auth if available
      final token = await _performAuthenticationWithFallback();
      // Persist token so it can be used for subsequent API calls
      _safeguardService.setPasswordAuthToken(token);
      // Notify parent about token
      if (widget.onPasswordAuthToken != null) {
        widget.onPasswordAuthToken!(token);
      }
      print('[AUTH] ✓ Authentication successful');
      return true;
    } catch (e) {
      print('[AUTH] ✗ Authentication failed: $e');
      
      // Provide specific guidance based on error
      final errorMsg = e.toString();
      String displayError = 'Authentication failed: $e';
      
      if (errorMsg.contains('WebView') || errorMsg.contains('rSTS') || errorMsg.contains('password=null')) {
        displayError = '''
Browser authentication encountered an issue.

✅ What you can do:

**Option 1: Upload Client Certificates (Recommended)**
1. Tap the menu button (⋮) in the top-right
2. Go to Account Settings  
3. Upload your client certificate and private key
4. Return and try again

**Option 2: Re-login in Browser**
1. Go back to Setup Screen
2. Clear the WebView (logout)
3. Login again
4. Click "Verify Authentication" to capture session
5. Return here and try again

📌 Client certificates are the most reliable method.
        '''.trim();
      } else if (errorMsg.contains('certificate') || errorMsg.contains('Certificate')) {
        displayError = '''
Client certificates are missing or invalid.

Please upload your certificates:
1. Tap the menu button (⋮) in the top-right
2. Go to Account Settings  
3. Upload your client certificate and private key
4. Return and try again
        '''.trim();
      }
      
      setState(() {
        _errorMessage = displayError;
      });
      return false;
    }
  }

  /// Load and persist account data from Safeguard API
  Future<bool> _loadAndPersistAccountData() async {
    try {
      final accountsData = await _safeguardService.getAccountsData();

      // Populate in-memory accounts map (handles empty lists)
      if (accountsData.accounts.isNotEmpty) {
        _populateAccountsMap(accountsData.accounts, accountsData.endpoint, treeData: accountsData.treeData);
      }

      // Save accounts to database for offline access
      if (widget.currentUsername != null) {
        // Collect ALL accounts from both flat list AND tree structure
        final allAccountIds = <String>{};
        final cachedAccountsMap = <String, CachedAccount>{};
        
        // Add from flat accounts list
        for (final acc in accountsData.accounts) {
          if (acc is Map<String, dynamic>) {
            final ca = CachedAccount.fromApiData(
              acc,
              widget.currentUsername!,
              accountsData.endpoint,
            );
            allAccountIds.add(ca.id);
            cachedAccountsMap[ca.id] = ca;
          }
        }
        
        // Add from tree structure (for accounts only in tree, not in flat list)
        if (accountsData.treeData?.containsKey('tree') ?? false) {
          _collectAccountsFromTreeForCaching(
            accountsData.treeData!['tree'] as List,
            cachedAccountsMap,
            allAccountIds,
            accountsData,
          );
        }
        
        final cachedAccounts = cachedAccountsMap.values.toList();
        
        print('[CACHE_PERSIST] === PERSISTING ${cachedAccounts.length} ACCOUNTS TO DATABASE (${allAccountIds.length} unique IDs) ===');
        
        // Log what we're about to persist
        for (final ca in cachedAccounts) {
          final rawName = ca.rawData['Name'] ?? 'N/A';
          print('[CACHE_PERSIST] Caching account: id=${ca.id}, name=${ca.name}, rawDataName=$rawName, url=${ca.url}, notes=${ca.notes}');
        }
        
        // Delete old cached accounts first to prevent duplicates
        await _databaseService.deleteCachedAccountsForUser(widget.currentUsername!);
        await _databaseService.insertCachedAccounts(cachedAccounts);
        print('[CACHE_PERSIST] ✅ Persisted ${cachedAccounts.length} accounts to database');
      }

      // Convert API response to AccountTree nodes and persist
      await _convertAndPersistAccountTree(accountsData);
      return true;
    } catch (e) {
      print('Error loading and persisting account data: $e');
      setState(() {
        _errorMessage = 'Failed to load accounts: $e';
      });
      return false;
    }
  }

  /// Convert Safeguard API response to AccountTree nodes and persist to database
  Future<void> _convertAndPersistAccountTree(
    AccountsDataResponse accountsData,
  ) async {
    if (widget.currentUsername == null) return;

    try {
      final accountTreeNodes = <AccountTree>[];
      int nodeId = 1;
      int sequenceOrder = 0; // Track original order from API

      // Build a lookup map of accountId -> full account details from the accounts list
      final accountDetailsMap = <String, Map<String, dynamic>>{};
      for (final account in accountsData.accounts) {
        if (account is Map<String, dynamic>) {
          final accountId = (account['Id'] ?? account['id'] ?? '').toString();
          if (accountId.isNotEmpty) {
            accountDetailsMap[accountId] = account;
            final name = account['Name'] ?? account['AccountName'] ?? 'Unknown';
            print('[TREE] Added account to map: key=$accountId, name=$name');
          }
        }
      }
      print('[TREE] Built account details map with ${accountDetailsMap.length} accounts: keys=${accountDetailsMap.keys.toList()}');

      // Convert tree data to AccountTree nodes
      if (accountsData.treeData?.containsKey('tree') ?? false) {
        final tree = accountsData.treeData!['tree'] as List;
        print('[TREE_CONVERT] === RAW TREE DATA FROM API ===');
        print('[TREE_CONVERT] Tree has ${tree.length} root nodes');
        
        // Log RAW JSON structure for debugging
        try {
          final treeJson = jsonEncode(tree);
          print('[TREE_CONVERT] RAW JSON: $treeJson');
        } catch (e) {
          print('[TREE_CONVERT] Could not encode tree to JSON: $e');
        }
        
        // Log the entire tree structure for debugging
        void logNode(Map<String, dynamic> node, String indent) {
          final name = node['folderName'] ?? node['Name'] ?? 'Unknown';
          final hasFolder = node.containsKey('folderId');
          final hasFolderName = node.containsKey('folderName');
          final hasId = node.containsKey('Id');
          final hasChildren = (node['children'] as List?)?.isNotEmpty ?? false;
          final hasChildrenList = node.containsKey('children') ? (node['children'] as List?)?.length ?? 0 : 0;
          print('[TREE_CONVERT] $indent- $name (keys=${node.keys.toList()}, folderId=$hasFolder, folderName=$hasFolderName, Id=$hasId, children=$hasChildrenList)');
          
          if (hasChildren) {
            final children = node['children'] as List;
            for (final child in children) {
              if (child is Map<String, dynamic>) {
                logNode(child, '$indent  ');
              }
            }
          }
        }
        
        for (final rootNode in tree) {
          if (rootNode is Map<String, dynamic>) {
            logNode(rootNode, '');
          }
        }

        void processNode(Map<String, dynamic> node, String? parentId) {
          sequenceOrder++; // Increment to preserve order
          // Determine if this is a folder
          // A node is a folder if it has folderId OR folderName (folder indicators take priority over Id)
          final hasFolderId = node.containsKey('folderId');
          final hasFolderName = node.containsKey('folderName');
          final hasAccountId = node.containsKey('Id');
          final hasChildren =
              node.containsKey('children') &&
              (node['children'] as List?)?.isNotEmpty == true;

          // CRITICAL: Folder type indicators (folderId, folderName) take priority over Id field
          // A folder can have an Id field (folder ID), but folderName/folderId indicate folder type
          final isFolder =
              hasFolderId ||
              hasFolderName ||
              (hasChildren && !hasAccountId);

          // Extract name with multiple fallbacks
          String name;
          if (isFolder) {
            name =
                (node['folderName'] ??
                        node['Name'] ??
                        node['Folder'] ??
                        'Folder')
                    .toString()
                    .trim();
            if (name.isEmpty) name = 'Unnamed Folder';
          } else {
            name =
                (node['Name'] ??
                        node['AccountName'] ??
                        node['folderName'] ??
                        node['Title'] ??
                        'Account')
                    .toString()
                    .trim();
            if (name.isEmpty) name = 'Unnamed Account';
          }

          print(
            '[DEBUG] processNode: nodeKeys=${node.keys.toList()}, isFolder=$isFolder, name="$name", children.count=${(node['children'] as List?)?.length ?? 0}',
          );

          // Extract account ID - try multiple key variations (case-insensitive)
          final accountIdValue = isFolder
              ? null
              : int.tryParse(
                  (node['Id'] ??
                          node['id'] ??
                          node['AccountId'] ??
                          node['accountId'] ??
                          node['EnterpriseAccountId'] ??
                          node['enterpriseAccountId'])
                      ?.toString() ??
                  '',
                );

          print('[TREE] Account ID extraction for "$name": raw ID=${node['Id']}, lowercase id=${node['id']}, enterpriseAccountId=${node['enterpriseAccountId']}, parsed value=$accountIdValue');

          // For account nodes, look up full account details and store for offline access
          Map<String, dynamic>? accountDataMap;
          if (!isFolder && accountIdValue != null) {
            final accountIdStr = accountIdValue.toString();
            print('[TREE] Looking up account ID: $accountIdStr in map with keys: ${accountDetailsMap.keys.toList()}');
            // First try to get from the accounts details map
            if (accountDetailsMap.containsKey(accountIdStr)) {
              accountDataMap = Map<String, dynamic>.from(accountDetailsMap[accountIdStr]!);
              print('[TREE] ✓ Found account details for ID $accountIdStr: Name=${accountDataMap['Name']}, AccountName=${accountDataMap['AccountName']}');
            } else {
              print('[TREE] ✗ Account ID $accountIdStr NOT found in accountDetailsMap!');
              // If not found in details map, create from tree node (fallback)
              accountDataMap = <String, dynamic>{
                'Name': node['Name'] ?? name,
                'AccountName':
                    node['AccountName'] ?? node['Name'] ?? 'Unknown Account',
                'Url': node['Url'] ?? '',
                'Notes': node['Notes'] ?? '',
                'HasPassword': node['HasPassword'] ?? false,
                'Id': accountIdValue,
                'EnterpriseAccountId': accountIdValue,
                ...node,
              };
            }
          }

          final treeNode = AccountTree(
            id: nodeId,
            username: widget.currentUsername!,
            name: name,
            isFolder: isFolder,
            parentId: parentId,
            accountId: accountIdValue?.toString(),
            syncedAt: DateTime.now(),
            accountData: accountDataMap,
            sequenceOrder: sequenceOrder,
          );
          accountTreeNodes.add(treeNode);
          nodeId++;

          // Process children recursively
          if (node.containsKey('children') && node['children'] is List) {
            final children = node['children'] as List;
            for (final child in children) {
              if (child is Map<String, dynamic>) {
                processNode(child, treeNode.id.toString());
              }
            }
          }
        }

        for (final rootNode in tree) {
          if (rootNode is Map<String, dynamic>) {
            processNode(rootNode, null);
          }
        }
      }

      // CRITICAL: Add any accounts from the flat list that aren't in the tree structure
      // This ensures all accounts appear in offline tree view
      final accountIdsInTree = accountTreeNodes
          .where((node) => !node.isFolder && node.accountId != null)
          .map((node) => node.accountId)
          .toSet();
      print('[TREE] Accounts in tree structure: $accountIdsInTree');
      
      for (final account in accountsData.accounts) {
        if (account is Map<String, dynamic>) {
          final accountId = (account['Id'] ?? account['id'] ?? '').toString();
          if (accountId.isNotEmpty && !accountIdsInTree.contains(accountId)) {
            // This account is not in the tree - add it as a child of the root folder
            print('[TREE] Adding account not in tree: id=$accountId, name=${account['Name']}');
            
            // Find root folder node (the Unternehmens-Vault or main folder)
            int? rootFolderId;
            for (final node in accountTreeNodes) {
              if (node.isFolder && node.parentId == null) {
                rootFolderId = node.id;
                break;
              }
            }
            
            if (rootFolderId != null) {
              nodeId++;
              final accountNode = AccountTree(
                id: nodeId,
                username: widget.currentUsername!,
                name: account['Name'] ?? account['AccountName'] ?? 'Unknown',
                isFolder: false,
                parentId: rootFolderId.toString(),
                accountId: accountId,
                syncedAt: DateTime.now(),
                accountData: account,
                sequenceOrder: (accountTreeNodes.length + 1),
              );
              accountTreeNodes.add(accountNode);
              print('[TREE] ✓ Added missing account node: ${accountNode.name}');
            }
          }
        }
      }
      
      // CRITICAL: Also persist all accounts to CachedAccounts table for offline access
      // Extract all account nodes (non-folder) from the tree
      final cachedAccountsList = <CachedAccount>[];
      for (final node in accountTreeNodes) {
        if (!node.isFolder && node.accountId != null && node.accountData != null) {
          try {
            final accountData = node.accountData!;
            final accountId = node.accountId!;
            final name = accountData['Name'] ?? accountData['AccountName'] ?? node.name;
            final url = accountData['Url']?.toString();
            final notes = accountData['Notes']?.toString();
            
            final cachedAccount = CachedAccount(
              id: accountId,
              username: widget.currentUsername!,
              name: name.toString(),
              accountName: accountData['AccountName']?.toString(),
              url: url,
              notes: notes,
              hasPassword: accountData['HasPassword'] ?? false,
              endpoint: accountsData.endpoint,
              cachedAt: DateTime.now(),
              rawData: accountData,
            );
            cachedAccountsList.add(cachedAccount);
            print('[TREE_PERSIST] Adding account to CachedAccounts: id=$accountId, name=$name, url=$url, notes=$notes');
          } catch (e) {
            print('[TREE_PERSIST] ⚠️ Error creating CachedAccount from tree node: $e');
          }
        }
      }
      
      // Persist all accounts to CachedAccounts table
      if (cachedAccountsList.isNotEmpty) {
        await _databaseService.deleteCachedAccountsForUser(widget.currentUsername!);
        await _databaseService.insertCachedAccounts(cachedAccountsList);
        print('[TREE_PERSIST] ✅ Persisted ${cachedAccountsList.length} accounts to CachedAccounts table');
      }
      
      // Log all nodes being persisted (for debugging folder structure)
      print('[TREE_PERSIST] === PERSISTING ${accountTreeNodes.length} TREE NODES ===');
      for (final node in accountTreeNodes) {
        if (node.isFolder) {
          print('[TREE_PERSIST]   FOLDER: id=${node.id}, name=${node.name}, parentId=${node.parentId}');
        } else {
          print('[TREE_PERSIST]   ACCOUNT: id=${node.id}, name=${node.name}, accountId=${node.accountId}, parentId=${node.parentId}');
        }
      }
      
      // Delete old tree data and insert new nodes
      await _databaseService.deleteAccountTreeForUser(widget.currentUsername!);
      if (accountTreeNodes.isNotEmpty) {
        await _databaseService.insertAccountTreeNodes(accountTreeNodes);
      }

      print('[TREE_PERSIST] ✅ Successfully persisted ${accountTreeNodes.length} tree nodes (${accountTreeNodes.where((n) => n.isFolder).length} folders, ${accountTreeNodes.where((n) => !n.isFolder).length} accounts) + ${cachedAccountsList.length} cached accounts');
    } catch (e) {
      print('Error converting and persisting tree: $e');
      rethrow;
    }
  }

  /// TEST METHOD: Test folder detection and persistence with mock API data
  /// This tests whether the "Home of John Davis" folder would be properly detected and persisted


  /// Comprehensive sync workflow: check prerequisites -> setup if needed -> auth -> load -> persist -> switch to online
  Future<void> _syncToOfflineMode(
    [AccountsDataResponse? freshData, Map<String, Map<String, dynamic>>? freshAccountsById]) async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Step 1: Check prerequisites only if we don't have fresh data
      // (If we have fresh data, user was just online and already authenticated)
      bool ready = true;
      if (freshData == null) {
        ready = await _checkPrerequisites();

        if (!ready) {
          // Step 2: Show setup screen overlay
          await _showSetupScreenOverlay();
          // After setup, recheck prerequisites
          ready = await _checkPrerequisites();
          if (!ready) {
            throw Exception(
              'Setup incomplete - cannot proceed without certificate and key',
            );
          }
        }
        
        // Step 3: Authenticate to Safeguard API
        final authSuccess = await _authenticateToSafeguardAPI();
        if (!authSuccess) {
          throw Exception('Failed to authenticate to Safeguard API');
        }

        // Step 4: Load account data from server
        final loadSuccess = await _loadAndPersistAccountData();
        if (!loadSuccess) {
          throw Exception('Failed to load account data from server');
        }
      } else {
        print('[SYNC_OFFLINE] Using fresh online data, skipping authentication');
        // Set the fresh data as our working data
        _accountsData = freshData;
        if (freshAccountsById != null) {
          _accountsById.clear();
          _accountsById.addAll(freshAccountsById);
        }
        
        // CRITICAL: Persist fresh online data to database for offline access
        print('[SYNC_OFFLINE] Persisting fresh online data to database...');
        if (_accountsData != null && widget.currentUsername != null) {
          // Persist cached accounts - collect from both flat list AND tree structure
          final allAccountIds = <String>{};
          final cachedAccountsMap = <String, CachedAccount>{};
          
          // Add from flat accounts list
          for (final acc in _accountsData!.accounts) {
            if (acc is Map<String, dynamic>) {
              final ca = CachedAccount.fromApiData(
                acc,
                widget.currentUsername!,
                _accountsData!.endpoint,
              );
              allAccountIds.add(ca.id);
              cachedAccountsMap[ca.id] = ca;
            }
          }
          
          // Add from tree structure (for accounts only in tree, not in flat list)
          if (_accountsData!.treeData?.containsKey('tree') ?? false) {
            _collectAccountsFromTreeForCaching(
              _accountsData!.treeData!['tree'] as List,
              cachedAccountsMap,
              allAccountIds,
              _accountsData!,
            );
          }
          
          final cachedAccounts = cachedAccountsMap.values.toList();
          
          await _databaseService.deleteCachedAccountsForUser(widget.currentUsername!);
          await _databaseService.insertCachedAccounts(cachedAccounts);
          print('[SYNC_OFFLINE] ✅ Persisted ${cachedAccounts.length} accounts (${allAccountIds.length} unique IDs)');
          
          // Persist account tree
          await _convertAndPersistAccountTree(_accountsData!);
          print('[SYNC_OFFLINE] ✅ Persisted account tree');
        }
      }

      // Step 4b: Cache the accounts data for offline display
      if (_accountsData != null) {
      }

      // Step 5: Update user's offline preference and reload
      final user = await _databaseService.getUser(widget.currentUsername!);
      if (user != null) {
        final updatedUser = user.copyWith(isOffline: true);
        await _databaseService.updateUser(updatedUser);
      }

      // Step 6: Load offline data and update UI
      if (mounted) {
        setState(() {
          _isOfflineMode = true;
        });
        await _loadAccountDataOffline();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Successfully synced offline data')),
        );
      }
    } catch (e) {
      print('Error in sync to offline mode: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Sync failed: $e';
          // Revert mode
          _isOfflineMode = false;
          _isLoading = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
      }
    }
  }

  /// Public method to load account data - called from Connection screen after successful auth
  void loadAccounts() {
    if (mounted) {
      if (_isOfflineMode) {
        _loadAccountDataOffline();
      } else {
        _loadAccountData();
      }
    }
  }

  Future<void> _loadAccountData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final accountsData = await _safeguardService.getAccountsData();

      // Build in-memory account lookup map (handles empty lists)
      if (accountsData.accounts.isNotEmpty) {
        _populateAccountsMap(accountsData.accounts, accountsData.endpoint, treeData: accountsData.treeData);
      }

      // Save accounts to database for offline access
      if (widget.currentUsername != null) {
        // CRITICAL: Collect ALL accounts from both flat list AND tree structure
        final allAccountIds = <String>{};
        final cachedAccountsMap = <String, CachedAccount>{};
        
        // Add from flat accounts list
        for (final acc in accountsData.accounts) {
          if (acc is Map<String, dynamic>) {
            final ca = CachedAccount.fromApiData(
              acc,
              widget.currentUsername!,
              accountsData.endpoint,
            );
            allAccountIds.add(ca.id);
            cachedAccountsMap[ca.id] = ca;
          }
        }
        
        // Add from tree structure (for accounts only in tree, not in flat list)
        if (accountsData.treeData?.containsKey('tree') ?? false) {
          _collectAccountsFromTreeForCaching(
            accountsData.treeData!['tree'] as List,
            cachedAccountsMap,
            allAccountIds,
            accountsData,
          );
        }
        
        final cachedAccounts = cachedAccountsMap.values.toList();
        
        // Log what we're caching
        print('[ACCOUNTS] === CACHING DEBUG (Total: ${cachedAccounts.length}) ===');
        for (final ca in cachedAccounts.take(5)) {
          print('[ACCOUNTS] Caching account: id=${ca.id}, name=${ca.name}, url=${ca.url}, notes=${ca.notes}');
        }
        
        // Delete old cached accounts first to prevent duplicates
        await _databaseService.deleteCachedAccountsForUser(widget.currentUsername!);
        await _databaseService.insertCachedAccounts(cachedAccounts);
        print('[ACCOUNTS] Saved ${cachedAccounts.length} accounts to database (${allAccountIds.length} unique IDs)');
      }

      // Also persist tree structure for offline use
      print('[DEBUG] _loadAccountData: Persisting tree to database...');
      await _convertAndPersistAccountTree(accountsData);

      setState(() {
        _accountsData = accountsData;
        _isLoading = false;
        // Expand the root folder by default
        _expandedNodes['root'] = true;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading accounts: $e';
        _isLoading = false;
      });
    }
  }

  /// Populate the in-memory accounts map for fast lookup during rendering
  void _populateAccountsMap(List<dynamic> accounts, String endpoint, {Map<String, dynamic>? treeData}) {
    _accountsById.clear();
    
    // First, add all accounts from the flat list
    for (final account in accounts) {
      if (account is Map<String, dynamic>) {
        final id = (account['Id'] ?? account['id'] ?? '').toString();
        if (id.isNotEmpty) {
          _accountsById[id] = account;
          print(
            '[ACCOUNTS] Mapped account: id=$id, name=${account['Name'] ?? account['name']}',
          );
        }
      }
    }
    
    // CRITICAL: If tree data exists, also collect accounts from tree structure
    // This ensures tree-only accounts (like newly added ones) are included
    if (treeData?.containsKey('tree') ?? false) {
      _collectAccountsFromTreeForAccountMap(treeData!['tree'] as List);
    }
    
    print('[ACCOUNTS] Built [${_accountsById.length}] accounts in memory map');
  }

  /// Collect accounts from tree structure and add to _accountsById map
  /// This ensures tree-only accounts are available for persistence and display
  void _collectAccountsFromTreeForAccountMap(List<dynamic> nodes) {
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      
      // Check if this node represents an account (has Id and is not just a folder)
      final hasAccountId = node.containsKey('Id') || node.containsKey('id') || node.containsKey('AccountId');
      if (hasAccountId) {
        final accountId = (node['Id'] ?? node['id'] ?? node['AccountId'])?.toString();
        if (accountId != null && !_accountsById.containsKey(accountId)) {
          // This account is in tree but not in flat list - add it
          print('[TREE_MAP] Adding tree-only account: id=$accountId, name=${node['Name']}');
          _accountsById[accountId] = node;
        }
      }
      
      // Recurse into children
      if (node['children'] is List) {
        _collectAccountsFromTreeForAccountMap(node['children'] as List<dynamic>);
      }
    }
  }

  void _toggleNodeExpanded(String nodeKey) {
    setState(() {
      _expandedNodes[nodeKey] = !(_expandedNodes[nodeKey] ?? false);
    });
  }

  void _togglePasswordVisibility(String accountId) {
    setState(() {
      _passwordVisibility[accountId] =
          !(_passwordVisibility[accountId] ?? false);
    });
  }

  void _copyToClipboard(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Filter tree structure based on search query
  List<Map<String, dynamic>> _filterTreeStructure(List<Map<String, dynamic>> tree) {
    if (_searchQuery.isEmpty) {
      return tree;
    }

    final filtered = <Map<String, dynamic>>[];

    for (final node in tree) {
      final filteredNode = _filterNode(node);
      if (filteredNode != null) {
        filtered.add(filteredNode);
      }
    }

    return filtered;
  }

  /// Recursively filter a node and its children based on search query
  Map<String, dynamic>? _filterNode(Map<String, dynamic> node) {
    // For account nodes, look up the account data to check accountName
    String searchText = '';
    
    if (_isAccount(node)) {
      // For offline accounts, use AccountName/Name from the node (populated during offline tree build)
      if (node.containsKey('_isOfflineAccount') && node['_isOfflineAccount'] == true) {
        // Check all possible field names for account name in offline mode
        final accountName = node['AccountName'] ?? node['accountName'] ?? node['Name'] ?? '';
        searchText = accountName.toString().toLowerCase();
      } else {
        // For online accounts, look up the account data
        final enterpriseAccountId = node['enterpriseAccountId'];
        final account = _getAccountById(enterpriseAccountId);
        if (account != null) {
          final accountName = account['AccountName'] ?? account['Name'] ?? '';
          searchText = accountName.toString().toLowerCase();
        }
      }
    } else {
      // For folders, don't filter - just pass through
      searchText = '';
    }
    
    // Check if current node matches
    final nodeMatches = searchText.isNotEmpty && searchText.contains(_searchQuery);
    
    // Get children - handle as List<dynamic> and convert safely
    final childrenRaw = node['children'];
    final filteredChildren = <Map<String, dynamic>>[];
    bool hasMatchedChildren = false;
    
    if (childrenRaw is List) {
      for (final child in childrenRaw) {
        if (child is Map<String, dynamic>) {
          final filteredChild = _filterNode(child);
          if (filteredChild != null) {
            filteredChildren.add(filteredChild);
            // Check if this child or its descendants are matched
            if (filteredChild['_searchMatched'] == true || 
                _hasMatchedDescendants(filteredChild)) {
              hasMatchedChildren = true;
            }
          }
        }
      }
    }
    
    // Include node if:
    // 1. Node matches search query, OR
    // 2. Any child is included after filtering
    if (nodeMatches || filteredChildren.isNotEmpty) {
      final result = Map<String, dynamic>.from(node);
      if (filteredChildren.isNotEmpty) {
        result['children'] = filteredChildren;
      }
      // Mark this node as matched by search (for auto-expand)
      if (nodeMatches) {
        result['_searchMatched'] = true;
      }
      // Mark folder as matched if it contains matched children
      if (hasMatchedChildren && !nodeMatches) {
        result['_searchMatched'] = true;
      }
      return result;
    }
    
    return null;
  }

  /// Helper to check if a node has matched descendants
  bool _hasMatchedDescendants(Map<String, dynamic> node) {
    if (node['_searchMatched'] == true) {
      return true;
    }
    
    final children = node['children'];
    if (children is List) {
      for (final child in children) {
        if (child is Map<String, dynamic> && _hasMatchedDescendants(child)) {
          return true;
        }
      }
    }
    
    return false;
  }

  /// Sort accounts by name with natural/alphanumeric ordering using collection package
  List<Map<String, dynamic>> _sortAccountsByName(
    List<Map<String, dynamic>> accounts,
    String order,
  ) {
    final sorted = List<Map<String, dynamic>>.from(accounts);
    
    sorted.sort((a, b) {
      final nameA = (a['Name'] ?? a['AccountName'] ?? '').toString();
      final nameB = (b['Name'] ?? b['AccountName'] ?? '').toString();
      final cmp = compareNatural(nameA, nameB);
      return order == 'asc' ? cmp : -cmp;
    });
    
    return sorted;
  }

  /// Build flat account list from tree structure with search and sort applied
  List<Map<String, dynamic>> _getFlatAccountList() {
    // Use cached accounts from _accountsById (populated during data load)
    var flatList = _accountsById.values.toList();

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      flatList = flatList.where((account) {
        final accountName =
            (account['AccountName'] ?? account['Name'] ?? '')
                .toString()
                .toLowerCase();
        return accountName.contains(_searchQuery);
      }).toList();
    }

    // Apply sorting
    flatList = _sortAccountsByName(flatList, _sortOrder);

    return flatList;
  }

  /// Fetch all passwords eagerly when in online mode - SEQUENTIAL to avoid database lock
  Future<void> _fetchAllPasswordsEagerly() async {
    if (_accountsData == null || _isOfflineMode) return;
    
    _isFetchingAllPasswords = true; // ← LOCK: Prevent concurrent caching
    print('[FETCH_ALL] 🔒 LOCK ACQUIRED: Preventing concurrent password fetches');
    
    try {
      print('[FETCH_ALL] === START (BATCH MODE WITH EXPLICIT FLUSH & CLEANUP) ===');
      
      // CLEANUP: Delete old cached passwords for this user to avoid stale data
      if (_safeguardService.databaseService != null && widget.currentUsername != null) {
        print('[FETCH_ALL] 🧹 Cleaning up old cached passwords for username=${widget.currentUsername}...');
        try {
          await _safeguardService.databaseService!.deleteCachedPasswordsForUser(widget.currentUsername!);
          print('[FETCH_ALL] ✅ Cleaned up old passwords');
        } catch (e) {
          print('[FETCH_ALL] ⚠️ Could not clean up old passwords: $e');
        }
      }
      
      // Collect ALL accounts from both flat list AND tree structure
      final collectedAccounts = <String, Map<String, dynamic>>{};
      
      // Add from flat accounts list
      for (final account in _accountsData!.accounts) {
        if (account is Map<String, dynamic>) {
          final id = account['Id']?.toString();
          if (id != null) collectedAccounts[id] = account;
        }
      }
      
      // Add from tree (for nested accounts)
      if (_accountsData!.treeData?['tree'] is List) {
        _collectAccountsFromTree(_accountsData!.treeData!['tree'] as List, collectedAccounts);
      }
      
      print('[FETCH_ALL] Collected ${collectedAccounts.length} total unique accounts');
      
      final accountsToCache = <String>[];
      final passwordsToCache = <String, String>{};
      final accountNames = <String, String>{};
      
      // PHASE 1: Fetch all passwords first WITHOUT database caching
      print('[FETCH_ALL] === PHASE 1: Fetching all passwords from API ===');
      int totalToFetch = 0;
      for (final MapEntry(key: id, value: account) in collectedAccounts.entries) {
        if (!(account['HasPassword'] ?? false)) {
          print('[FETCH_ALL] Skipping $id: no password flag');
          continue;
        }
        totalToFetch++;
        
        print('[FETCH_ALL] 🌐 Fetching password for account $id from API...');
        _passwordCache[id] = {'status': 'loading'};
        try {
          final pwd = await _safeguardService.getAccountPassword(_accountsData!.endpoint, id);
          if (pwd != null) {
            final val = pwd is String ? pwd : (pwd['Password'] ?? '');
            if (val.isNotEmpty) {
              accountsToCache.add(id);
              passwordsToCache[id] = val;
              accountNames[id] = account['Name']?.toString() ?? 'Unknown';
              print('[FETCH_ALL] ✅ Fetched password for $id (length=${val.length})');
            } else {
              print('[FETCH_ALL] ⚠️ Empty password for $id');
            }
          } else {
            print('[FETCH_ALL] ❌ No password data for $id');
          }
        } catch (e) {
          print('[FETCH_ALL] 💥 Error fetching $id: $e');
          if (mounted) setState(() { _passwordCache[id] = {'error': e.toString()}; });
        }
      }
      
      print('[FETCH_ALL] === PHASE 1 COMPLETE: Fetched ${accountsToCache.length}/$totalToFetch passwords ===');
      
      if (accountsToCache.isEmpty) {
        print('[FETCH_ALL] ⚠️ No passwords to cache, returning early');
        return;
      }
      
      // PHASE 2: Cache ALL passwords sequentially with LONG delays to ensure SQLite commits
      print('[FETCH_ALL] === PHASE 2: Sequential caching to database with extended commit delays ===');
      int s = 0, f = 0;
      for (final id in accountsToCache) {
        try {
          print('[FETCH_ALL] 💾 [$s+1/${accountsToCache.length}] Caching $id...');
          final cacheStartTime = DateTime.now();
          
          // Get the account details for expiration dates
          final account = collectedAccounts[id];
          final expirationDateStr = account?['ExpirationDate'] as String?;
          final createdDateStr = account?['CreatedDate'] as String?;
          final accountExpirationDate = expirationDateStr != null ? DateTime.tryParse(expirationDateStr) : null;
          final accountCreatedDate = createdDateStr != null ? DateTime.tryParse(createdDateStr) : null;
          
          await _safeguardService.cachePassword(
            accountId: id, 
            passwordValue: passwordsToCache[id]!,
            accountName: accountNames[id]!,
            usernameParam: widget.currentUsername,
            accountExpirationDate: accountExpirationDate,
            accountCreatedDate: accountCreatedDate,
          );
          print('[FETCH_ALL] ⏳ Cache complete for $id (${DateTime.now().difference(cacheStartTime).inMilliseconds}ms), flushing...');
          // CRITICAL: Wait 1500ms to allow SQLite to fully commit to persistent storage
          await Future.delayed(const Duration(milliseconds: 1500));
          print('[FETCH_ALL] ✓ Flush complete for $id');
          
          // Update memory cache with actual password
          print('[FETCH_ALL] 🔄 [BEFORE setState] _passwordCache[$id] = ${_passwordCache[id]}');
          print('[FETCH_ALL] 🔄 [UPDATING] Setting password for $id to length=${passwordsToCache[id]!.length}');
          
          if (mounted) {
            setState(() { 
              _passwordCache[id] = {'Password': passwordsToCache[id]!};
              print('[FETCH_ALL] 🔄 [AFTER setState] _passwordCache[$id] = ${_passwordCache[id]}');
            });
          } else {
            print('[FETCH_ALL] ⚠️ [NOT MOUNTED] Cannot update cache for $id');
          }
          
          // Verify the memory cache was actually updated
          print('[FETCH_ALL] 🔍 [VERIFY] _passwordCache[$id].keys = ${_passwordCache[id]?.keys.toList()}');
          
          s++;
          print('[FETCH_ALL] ✅ [$s] $id SUCCESS');
        } catch (e) {
          print('[FETCH_ALL] ❌ Caching failed for $id: $e');
          f++;
        }
      }
      
      print('[FETCH_ALL] === END: $s stored, $f failed ===');
      
      // DIAGNOSTIC: Dump database state after caching complete
      if (_safeguardService.databaseService != null && widget.currentUsername != null) {
        // Wait extra time to ensure all SQLite commits are persisted to disk
        print('[FETCH_ALL] ⏳ Waiting 2000ms for SQLite to fully flush to disk...');
        await Future.delayed(const Duration(milliseconds: 2000));
        print('[FETCH_ALL] ✓ Proceeding to diagnostic dump');
        await _safeguardService.databaseService!.diagnosticDump(widget.currentUsername!);
      }
    } finally {
      _isFetchingAllPasswords = false; // ← LOCK RELEASED
      print('[FETCH_ALL] 🔓 LOCK RELEASED: Concurrent caching now allowed');
    }
  }
  
  /// Recursively collect accounts from tree nodes
  void _collectAccountsFromTree(List<dynamic> nodes, Map<String, Map<String, dynamic>> result) {
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      
      // If node has account detail, extract it
      final accountData = node['accountData'];
      if (accountData is Map<String, dynamic>) {
        final id = accountData['Id']?.toString();
        if (id != null) result[id] = accountData;
      }
      
      // Recurse into children
      if (node['children'] is List) {
        _collectAccountsFromTree(node['children'] as List<dynamic>, result);
      }
    }
  }

  /// Collect all accounts from tree structure and convert to CachedAccount objects
  /// This ensures accounts only in the tree (not in flat list) are also cached for offline
  void _collectAccountsFromTreeForCaching(
    List<dynamic> nodes,
    Map<String, CachedAccount> cachedAccountsMap,
    Set<String> processedIds,
    AccountsDataResponse accountsData,
  ) {
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      
      // Check if this node represents an account
      final hasAccountId = node.containsKey('Id') || node.containsKey('id') || node.containsKey('AccountId');
      if (hasAccountId) {
        final accountId = (node['Id'] ?? node['id'] ?? node['AccountId'])?.toString();
        if (accountId != null && !processedIds.contains(accountId)) {
          // This account is in tree but not in flat list - create CachedAccount from tree node
          print('[TREE_CACHE] Found tree-only account: id=$accountId, name=${node['Name']}');
          try {
            final ca = CachedAccount.fromApiData(
              node,
              widget.currentUsername!,
              accountsData.endpoint,
            );
            cachedAccountsMap[ca.id] = ca;
            processedIds.add(accountId);
            print('[TREE_CACHE] ✓ Created CachedAccount for tree-only account: ${ca.name}');
          } catch (e) {
            print('[TREE_CACHE] ✗ Failed to create CachedAccount from tree node: $e');
          }
        }
      }
      
      // Recurse into children
      if (node['children'] is List) {
        _collectAccountsFromTreeForCaching(
          node['children'] as List<dynamic>,
          cachedAccountsMap,
          processedIds,
          accountsData,
        );
      }
    }
  }

  Future<void> _fetchPasswordIfNeeded(Map<String, dynamic> account) async {
    print('[FETCH_PWD] === START _fetchPasswordIfNeeded ===');
    
    // Use 'Id' (uppercase) as that's what the API returns
    final accountId = account['Id']?.toString();
    print('[FETCH_PWD] Extracted accountId: $accountId, account.keys=${account.keys.toList()}');
    
    if (accountId == null) {
      print('[FETCH_PWD] ERROR: Cannot fetch password - no Id found in account: ${account.keys}');
      return;
    }

    print('[FETCH_PWD] Checking password for account ID: $accountId');

    // Check if already cached or fetching
    if (_passwordCache.containsKey(accountId)) {
      print('[FETCH_PWD] Already in cache, skipping: $accountId');
      return;
    }
    
    // In offline mode, passwords should already be pre-loaded or unavailable
    // Don't attempt to fetch - cache is pre-populated during offline mode switch
    if (_isOfflineMode) {
      print('[FETCH_PWD] In offline mode, passwords already pre-loaded from database');
      print('[FETCH_PWD] Skipping fetch: _isOfflineMode=true');
      return;
    }
    
    print('[FETCH_PWD] mounted=$mounted');
    if (!mounted) {
      print('[FETCH_PWD] Not mounted, skipping');
      return;
    }

    // Mark as fetching to prevent duplicate requests
    print('[FETCH_PWD] Setting loading status for $accountId');
    _passwordCache[accountId] = {'status': 'loading'};
    print('[FETCH_PWD] Cache state after setting loading: ${_passwordCache[accountId]}');

    try {
      final hasPassword = account['HasPassword'] ?? false;
      print('[FETCH_PWD] Account $accountId HasPassword: $hasPassword');
      print('[FETCH_PWD] _accountsData=${_accountsData != null ? "SET" : "NULL"}');

      // Fetch passwords only in ONLINE mode
      if (hasPassword && _accountsData != null) {
        print('[FETCH_PWD] Starting async password fetch for account: $accountId from online endpoint');
        final password = await _safeguardService.getAccountPassword(
          _accountsData!.endpoint,
          accountId,
        );
        
        print('[FETCH_PWD] Password fetch completed, password=${password != null ? "RECEIVED" : "NULL"}');
        print('[FETCH_PWD] mounted=$mounted before setState');

        if (mounted) {
          if (password != null) {
            print('[FETCH_PWD] Password fetched successfully for: $accountId, type=${password.runtimeType}');
            print('[FETCH_PWD] Calling setState with password');
            
            // Extract password value
            final passwordValue = password is String ? password : (password['Password'] ?? '');
            print('[FETCH_PWD] Extracted passwordValue for $accountId: length=${passwordValue.length}, isString=${password is String}');
            
            // Only cache if we have a non-empty password
            if (passwordValue.isNotEmpty) {
              // 🔒 CRITICAL: Skip caching if bulk fetch is in progress to avoid database lock
              if (_isFetchingAllPasswords) {
                print('[FETCH_PWD] ⏭️  SKIP cache for $accountId: Bulk password fetch in progress (lock held)');
                if (mounted) setState(() { _passwordCache[accountId] = password; });
              } else {
                print('[FETCH_PWD] ⏳ Caching password to database for $accountId...');
                try {
                  // Get account expiration dates
                  final expirationDateStr = account['ExpirationDate'] as String?;
                  final createdDateStr = account['CreatedDate'] as String?;
                  final accountExpirationDate = expirationDateStr != null ? DateTime.tryParse(expirationDateStr) : null;
                  final accountCreatedDate = createdDateStr != null ? DateTime.tryParse(createdDateStr) : null;
                  
                  // AWAIT the database write to complete before proceeding
                  await _safeguardService.cachePassword(
                    accountId: accountId,
                    passwordValue: passwordValue,
                    accountName: account['Name']?.toString() ?? 'Unknown',
                    usernameParam: widget.currentUsername,
                    accountExpirationDate: accountExpirationDate,
                    accountCreatedDate: accountCreatedDate,
                  );
                  print('[FETCH_PWD] ✅ Database write complete for $accountId');
                } catch (e) {
                  print('[FETCH_PWD] ❌ ERROR caching password for $accountId: $e');
                }
              }
            } else {
              print('[FETCH_PWD] ⚠️  Skipping cache: password value is empty for $accountId');
            }
            
            if (mounted) {
              setState(() {
                _passwordCache[accountId] = password;
                print('[FETCH_PWD] After setState, cache[accountId]=${_passwordCache[accountId]}');
              });
            }
          } else {
            print('[FETCH_PWD] ERROR: Password response was null for: $accountId');
            setState(() {
              _passwordCache[accountId] = {'error': 'Password was null'};
            });
          }
        } else {
          print('[FETCH_PWD] ERROR: Not mounted when trying to setState');
        }
      } else {
        print('[FETCH_PWD] Skipping fetch: hasPassword=$hasPassword, _accountsData=${_accountsData != null}');
        // Mark as unavailable
        _passwordCache[accountId] = {'unavailable': true};
      }
    } catch (e) {
      print('[FETCH_PWD] Exception during fetch: $e');
      if (mounted) {
        setState(() {
          _passwordCache[accountId] = {'error': e.toString()};
        });
      }
    }
    
    print('[FETCH_PWD] === END _fetchPasswordIfNeeded ===');
  }

  /// Get account by enterprise account ID (works with both int and string IDs)
  /// Searches: in-memory map, API response, and cached data
  Map<String, dynamic>? _getAccountById(dynamic accountId) {
    if (accountId == null) return null;
    
    final idStr = accountId.toString();
    
    // First check in-memory map (populated from both online and offline data)
    if (_accountsById.containsKey(idStr)) {
      return _accountsById[idStr];
    }

    // Fallback: search in API response if available
    final accountsSource = _accountsData;
    if (accountsSource == null) return null;
    
    try {
      final accountsList = accountsSource.accounts;
      for (final acc in accountsList) {
        if (acc is Map<String, dynamic>) {
          // Try matching by Id field
          if (acc['Id']?.toString() == idStr) {
            return acc;
          }
        }
      }
        } catch (e) {
      print('[DEBUG] Error searching accounts: $e');
    }
    
    return null;
  }

  /// Build tree structure from preferences (online mode)
  /// Returns a list of root tree nodes
  List<Map<String, dynamic>> _buildTreestructure() {
    // Use current view data: online in online mode, DB data in offline mode
    final accountsSource = _accountsData;
    
    if (accountsSource == null) {
      print('[TREE] No accounts source available (both online and cached are null)');
      return [];
    }

    // If treeData exists, use it
    if (accountsSource.treeData != null) {
      try {
        final tree = accountsSource.treeData?['tree'];
        if (tree is List && tree.isNotEmpty) {
          print('[TREE] Found tree with ${tree.length} root node(s)');
          for (var i = 0; i < tree.length; i++) {
            final node = tree[i];
            if (node is Map<String, dynamic>) {
              print(
                '[TREE] Root node $i: folderName=${node['folderName']}, children=${(node['children'] as List?)?.length ?? 0}',
              );
            }
          }
          // Convert each node in the list, ensuring proper type structure
          return tree.map((node) {
            if (node is Map<String, dynamic>) {
              return _normalizeTreeNode(node);
            }
            return <String, dynamic>{};
          }).toList();
        } else {
          print('[TREE] Tree is not a list or is empty: ${tree.runtimeType}');
        }
      } catch (e) {
        print('[TREE] Error building tree structure: $e');
      }
    } else {
      print('[TREE] No tree preference available - building fallback tree from accounts list');
    }

    // Fallback: If no tree data or tree is empty, build a simple tree from flat accounts list
    if (accountsSource.accounts.isNotEmpty) {
      print('[TREE] Building fallback tree with ${accountsSource.accounts.length} accounts under root folder');
      final rootFolder = {
        'folderName': accountsSource.folderName,
        'folderId': 'root',
        'children': accountsSource.accounts.map((account) {
          if (account is Map<String, dynamic>) {
            return {
              'Id': account['Id'] ?? account['id'] ?? 'unknown',
              'Name': account['Name'] ?? account['name'] ?? 'Unnamed Account',
              'children': [],
              ...account, // Include all original fields
            };
          }
          return <String, dynamic>{};
        }).toList(),
      };
      return [rootFolder];
    }

    print('[TREE] No tree data and no accounts available');
    return [];
  }

  /// Recursively normalize a tree node to ensure proper types
  Map<String, dynamic> _normalizeTreeNode(dynamic node) {
    if (node is! Map<String, dynamic>) {
      return <String, dynamic>{};
    }

    final normalized = Map<String, dynamic>.from(node);

    // Normalize children if present
    final children = node['children'];
    if (children is List) {
      normalized['children'] = children.map((child) {
        if (child is Map<String, dynamic>) {
          return _normalizeTreeNode(child);
        }
        return <String, dynamic>{};
      }).toList();
    }

    return normalized;
  }

  /// Build tree structure from offline folders map
  /// Returns a list of root tree nodes from persisted data
  List<Map<String, dynamic>> _buildOfflineTreeStructure() {
    if (_folders.isEmpty) {
      print('[OFFLINE TREE] No folders data available');
      return [];
    }

    try {
      final rootNodes = <Map<String, dynamic>>[];

      // Find all root nodes (parentId == null)
      for (final nodeEntry in _folders.entries) {
        final node = nodeEntry.value as Map<String, dynamic>;
        if (node['parentId'] == null) {
          final treeNode = _buildOfflineTreeNode(node);
          rootNodes.add(treeNode);
        }
      }

      print('[OFFLINE TREE] Found ${rootNodes.length} root node(s)');
      return rootNodes;
    } catch (e) {
      print('[OFFLINE TREE] Error building offline tree: $e');
    }
    return [];
  }

  /// Build a tree node recursively from offline folders data
  Map<String, dynamic> _buildOfflineTreeNode(Map<String, dynamic> node) {
    final nodeId = node['id']?.toString() ?? 'unknown';
    final children = <Map<String, dynamic>>[];

    // Extract folder name with VERY comprehensive fallback
    final rawName = node['name'];
    String folderName = '';
    if (rawName != null) {
      folderName = rawName.toString().trim();
    }
    if (folderName.isEmpty) {
      // Fallback to other possible name fields from API or database
      for (final key in [
        'folderName',
        'Folder',
        'accountName',
        'AccountName',
        'title',
        'Title',
        'Name',
      ]) {
        if (node[key] != null) {
          final val = node[key].toString().trim();
          if (val.isNotEmpty && val != 'Unknown') {
            folderName = val;
            break;
          }
        }
      }
    }
    if (folderName.isEmpty) {
      folderName = node['isFolder'] == true ? 'Unnamed Folder' : 'Unnamed Item';
    }

    print(
      '[DEBUG] _buildOfflineTreeNode: id=$nodeId, rawName=$rawName, folderName="$folderName", isFolder=${node['isFolder']}, nodeKeys=${node.keys.toList()}',
    );
    
    // Debug: Print the actual node data for account nodes
    if (node['isFolder'] != true) {
      print('[OFFLINE_DEBUG] Account node data: $node');
      if (node['accountData'] != null) {
        print('[OFFLINE_DEBUG] AccountData content: ${node['accountData']}');
      }
    }

    // Find all children of this node
    for (final childEntry in _folders.entries) {
      final child = childEntry.value as Map<String, dynamic>;
      if (child['parentId']?.toString() == nodeId) {
        children.add(_buildOfflineTreeNode(child));
      }
    }

    // For account nodes (isFolder=false), include account data
    final result = {
      'folderName': folderName,
      'folderId': node['id'],
      'isFolder': node['isFolder'],
      'accountId': node['accountId'],
      'children': children,
    };

    // If this is an account node (not a folder), merge in account data and mark as offline
    if (node['isFolder'] != true) {
      // Mark as offline account node
      result['_isOfflineAccount'] = true;
      
      // Try to get account data from multiple sources
      Map<String, dynamic>? accountData;
      String? accountId = node['accountId'];  // May be null from database
      
      print('[OFFLINE_DEBUG] Processing account node: accountId from DB=$accountId, nodeId=$nodeId');
      
      // FIRST: Extract the actual account ID from node's accountData if not already set - try multiple key variations
      if (accountId == null && node['accountData'] != null && (node['accountData'] as Map).isNotEmpty) {
        final nodeAccountData = node['accountData'] as Map<String, dynamic>;
        accountId = nodeAccountData['Id']?.toString() ?? 
                    nodeAccountData['id']?.toString() ??
                    nodeAccountData['EnterpriseAccountId']?.toString() ??
                    nodeAccountData['enterpriseAccountId']?.toString();
        print('[OFFLINE] Extracted accountId from node accountData: $accountId (tried Id, id, EnterpriseAccountId, enterpriseAccountId)');
      }
      
      // PRIORITY 1: Try _accountsById map FIRST (populated from cached accounts with real names)
      if (accountId != null) {
        final idStr = accountId.toString();
        print('[OFFLINE] Looking up in _accountsById for key: "$idStr"');
        print('[OFFLINE] _accountsById keys available: ${_accountsById.keys.toList()}');
        if (_accountsById.containsKey(idStr)) {
          accountData = _accountsById[idStr];
          print('[OFFLINE] ✓ FOUND in _accountsById for id=$idStr: name=${accountData?['Name']}, url=${accountData?['Url']}, notes=${accountData?['Notes']}');
        } else {
          print('[OFFLINE] ✗ NOT FOUND in _accountsById: id=$idStr');
        }
      } else {
        print('[OFFLINE] accountId is null, cannot lookup in _accountsById');
      }
      
      // PRIORITY 2: Fall back to accountData in the node itself (may have generic names)
      if (accountData == null && node['accountData'] != null && (node['accountData'] as Map).isNotEmpty) {
        accountData = node['accountData'] as Map<String, dynamic>;
        print('[OFFLINE] Fallback: Using accountData from node (from merged _accountsById data): url=${accountData['Url']}, notes=${accountData['Notes']}');
      }
      
      // Third try current accounts data (online or cached)
      if (accountData == null && accountId != null) {
        final accountsSource = _accountsData;
        if (accountsSource != null) {
          try {
            accountData = accountsSource.accounts
                .cast<Map<String, dynamic>>()
                .firstWhere(
                  (acc) => acc['Id']?.toString() == accountId?.toString(),
                  orElse: () => {},
                );
            if (accountData.isNotEmpty ?? false) {
              print('[OFFLINE] Found accountData in accountsSource for accountId=$accountId');
            }
          } catch (e) {
            accountData = null;
          }
        } else {
          print('[OFFLINE] No accountsSource available (_accountsData is null)');
        }
      }
      
      // Populate result with account data if found
      if (accountData != null && accountData.isNotEmpty) {
        result['Name'] = accountData['Name'] ?? node['name'] ?? 'Unknown';
        result['AccountName'] =
            accountData['AccountName'] ??
            accountData['name'] ??
            'Unknown Account';
        result['Url'] = accountData['Url'] ?? accountData['URL'] ?? '';
        result['Notes'] = accountData['Notes'] ?? '';
        result['HasPassword'] = accountData['HasPassword'] ?? false;
        result['Id'] = accountId;
        // Include date fields for proper expiration display
        result['CreatedDate'] = accountData['CreatedDate'];
        result['ExpirationDate'] = accountData['ExpirationDate'];
        print('[OFFLINE] ✓ Populated account result for $accountId:');
        print('[OFFLINE]   Name=${result['Name']}, AccountName=${result['AccountName']}');
        print('[OFFLINE]   Url=${result['Url']}, Notes=${result['Notes']}');
        print('[OFFLINE]   HasPassword=${result['HasPassword']}');
        print('[OFFLINE]   CreatedDate=${result['CreatedDate']}, ExpirationDate=${result['ExpirationDate']}');
      } else {
        // No account data available, use basic info
        result['Name'] = node['name'] ?? 'Unknown';
        result['AccountName'] = 'Unknown Account';
        result['Url'] = '';
        result['Notes'] = '';
        result['HasPassword'] = false;
        result['Id'] = accountId;
        result['CreatedDate'] = null;
        result['ExpirationDate'] = null;
        print('[OFFLINE] ✗ No account data found for accountId=$accountId, used fallback (result will be empty: Url and Notes)');
      }
    }

    return result;
  }

  /// Get children of a tree node
  List<Map<String, dynamic>> _getNodeChildren(Map<String, dynamic> node) {
    final children = node['children'];
    if (children is List) {
      return children.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Check if node is a folder (has folderId and folderName, or isFolder=true)
  bool _isFolder(Map<String, dynamic> node) {
    if (node.containsKey('folderId') && node.containsKey('folderName')) {
      return true;
    }
    // For offline nodes, check if explicitly marked as folder
    if (node.containsKey('isFolder')) {
      return node['isFolder'] == true;
    }
    return false;
  }

  /// Check if node is an account (has enterpriseAccountId or accountId with isFolder=false)
  bool _isAccount(Map<String, dynamic> node) {
    // Online mode: has enterpriseAccountId
    if (node.containsKey('enterpriseAccountId')) {
      return true;
    }
    // Offline mode: has accountId and isFolder=false
    if (node.containsKey('accountId') &&
        node.containsKey('isFolder') &&
        node['isFolder'] == false) {
      return true;
    }
    return false;
  }

  void _showAccountDetailsDialog(Map<String, dynamic> account) {
    bool localShowPassword = false;
    String? copiedNotification; // Track copy notification
    
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 600, maxHeight: 800),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(12),
                          topRight: Radius.circular(12),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              account['Name'] ?? account['AccountName'] ?? 'Account Details',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: _buildAccountCardWithLocalState(
                              account,
                              'dialog_account_${account['Id']}',
                              context,
                              localShowPassword ?? false,
                              (show) {
                                setDialogState(() {
                                  localShowPassword = show;
                                });
                              },
                              (String field) {
                                // Show copy notification
                                setDialogState(() {
                                  copiedNotification = field;
                                });
                                // Hide after 2 seconds
                                Future.delayed(const Duration(seconds: 2), () {
                                  setDialogState(() {
                                    copiedNotification = null;
                                  });
                                });
                              },
                            ),
                          ),
                          // Copy notification overlay
                          if (copiedNotification != null)
                            Positioned(
                              bottom: 16,
                              left: 16,
                              right: 16,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade800,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.check_circle, color: Colors.white, size: 20),
                                    const SizedBox(width: 12),
                                    Text(
                                      'Copied to clipboard',
                                      style: const TextStyle(color: Colors.white, fontSize: 14),
                                    ),
                                  ],
                                ),
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
        );
      },
    );
  }

  Widget _buildAccountListSection() {
    final accounts = _getFlatAccountList();
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: ExpansionTile(
        initiallyExpanded: _accountListExpanded,
        onExpansionChanged: (expanded) {
          setState(() {
            _accountListExpanded = expanded;
          });
        },
        title: Row(
          children: [
            const Icon(Icons.format_list_bulleted, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Account List (${accounts.length})',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
            // Sort buttons in trailing
            IconButton(
              icon: Icon(
                Icons.arrow_upward,
                size: 18,
                color: _sortOrder == 'asc' ? Colors.blue : Colors.grey,
              ),
              onPressed: () => _toggleSortOrder('asc'),
              tooltip: 'Sort A→Z',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            IconButton(
              icon: Icon(
                Icons.arrow_downward,
                size: 18,
                color: _sortOrder == 'desc' ? Colors.blue : Colors.grey,
              ),
              onPressed: () => _toggleSortOrder('desc'),
              tooltip: 'Sort Z→A',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ],
        ),
        children: [
          if (accounts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _searchQuery.isNotEmpty
                    ? 'No accounts match your search'
                    : 'No accounts available',
                style: TextStyle(color: Colors.grey.shade600),
                textAlign: TextAlign.center,
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: accounts.length,
              itemBuilder: (context, index) {
                final account = accounts[index];
                final accountName =
                    account['Name'] ?? account['AccountName'] ?? 'Unknown';
                
                // Check if account is expired
                var expirationDateStr = account['ExpirationDate'] as String?;
                final expirationDate = expirationDateStr != null ? DateTime.tryParse(expirationDateStr) : null;
                final isAccountExpired = expirationDate != null && DateTime.now().isAfter(expirationDate);
                
                return ListTile(
                  leading: isAccountExpired
                      ? Tooltip(
                          message: 'Account expired on ${_formatDate(expirationDate)}',
                          child: Icon(Icons.warning, size: 18, color: Colors.red.shade700),
                        )
                      : Icon(Icons.lock, size: 18, color: Colors.blue.shade700),
                  title: Text(
                    accountName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _showAccountDetailsDialog(account),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(Map<String, dynamic> account, String accountKey) {
    print('[ACCOUNT_CARD] Rendering account card with data: ${account.keys.toList()}');
    print('[ACCOUNT_CARD] Full account object: $account');
    
    final name = account['Name'] ?? 'Unknown';
    final accountName = account['AccountName'] ?? 'Unknown Account';
    final url = account['Url'] ?? account['URL'] ?? '';
    final notes = account['Notes'] ?? '';
    final hasPassword = account['HasPassword'] ?? false;
    final accountId = account['Id']?.toString() ?? '';
    
    // Extract date information
    var createdDateStr = account['CreatedDate'] as String?;
    var expirationDateStr = account['ExpirationDate'] as String?;
    
    print('[ACCOUNT_CARD] Initial date extraction: createdDateStr=$createdDateStr, expirationDateStr=$expirationDateStr');
    
    // If dates are missing, try to look them up from _accountsById (works for both online and offline)
    if ((createdDateStr == null || expirationDateStr == null) && accountId.isNotEmpty) {
      print('[ACCOUNT_CARD] Dates missing, looking up in _accountsById for accountId=$accountId');
      if (_accountsById.containsKey(accountId)) {
        final cachedAccountData = _accountsById[accountId];
        if (cachedAccountData != null) {
          if (createdDateStr == null) {
            createdDateStr = cachedAccountData['CreatedDate'] as String?;
            print('[ACCOUNT_CARD] Found CreatedDate from _accountsById: $createdDateStr');
          }
          if (expirationDateStr == null) {
            expirationDateStr = cachedAccountData['ExpirationDate'] as String?;
            print('[ACCOUNT_CARD] Found ExpirationDate from _accountsById: $expirationDateStr');
          }
        }
      }
      
      // Additional fallback: search in _accountsData if dates still missing (for online tree view accounts)
      if ((createdDateStr == null || expirationDateStr == null) && _accountsData != null) {
        print('[ACCOUNT_CARD] Dates still missing, searching in _accountsData for accountId=$accountId');
        try {
          final accountFromApi = _accountsData!.accounts
              .cast<Map<String, dynamic>>()
              .firstWhere(
                (acc) {
                  final accId = acc['Id']?.toString() ?? acc['id']?.toString();
                  return accId == accountId;
                },
                orElse: () => <String, dynamic>{},
              );
          
          if (accountFromApi.isNotEmpty) {
            if (createdDateStr == null) {
              createdDateStr = accountFromApi['CreatedDate'] as String?;
              print('[ACCOUNT_CARD] Found CreatedDate from _accountsData: $createdDateStr');
            }
            if (expirationDateStr == null) {
              expirationDateStr = accountFromApi['ExpirationDate'] as String?;
              print('[ACCOUNT_CARD] Found ExpirationDate from _accountsData: $expirationDateStr');
            }
          }
        } catch (e) {
          print('[ACCOUNT_CARD] Error searching _accountsData: $e');
        }
      }
    }
    
    // Fallback: check for dates in nested accountData field (from offline tree nodes)
    if ((createdDateStr == null || expirationDateStr == null) && account.containsKey('accountData')) {
      final accountData = account['accountData'];
      if (accountData is Map<String, dynamic>) {
        if (createdDateStr == null) {
          createdDateStr = accountData['CreatedDate'] as String?;
          if (createdDateStr != null) print('[ACCOUNT_CARD] Found CreatedDate from nested accountData: $createdDateStr');
        }
        if (expirationDateStr == null) {
          expirationDateStr = accountData['ExpirationDate'] as String?;
          if (expirationDateStr != null) print('[ACCOUNT_CARD] Found ExpirationDate from nested accountData: $expirationDateStr');
        }
      }
    }
    
    final createdDate = createdDateStr != null ? DateTime.tryParse(createdDateStr) : null;
    final expirationDate = expirationDateStr != null ? DateTime.tryParse(expirationDateStr) : null;
    final isAccountExpired = expirationDate != null && DateTime.now().isAfter(expirationDate);
    
    print('[ACCOUNT_CARD] Expiration check: accountId="$accountId", expirationDateStr="$expirationDateStr", expirationDate=$expirationDate, isAccountExpired=$isAccountExpired, now=${DateTime.now()}, expiredCheck=${expirationDate != null ? (DateTime.now().isAfter(expirationDate) ? "YES-EXPIRED" : "NO-NOT-YET") : "NO-DATE"}');
    
    print('[ACCOUNT_CARD] Extracted: name=$name, accountName=$accountName, url="$url", notes="$notes", hasPassword=$hasPassword, accountId="$accountId"');
    print('[ACCOUNT_CARD] Dates: created=$createdDate, expiration=$expirationDate, isExpired=$isAccountExpired');
    print('[ACCOUNT_CARD] _passwordCache keys available: ${_passwordCache.keys.toList()}');
    print('[ACCOUNT_CARD] Looking for accountId="$accountId" in cache: ${_passwordCache.containsKey(accountId)}');
    if (_passwordCache.containsKey(accountId)) {
      print('[ACCOUNT_CARD] Found in cache: ${_passwordCache[accountId]}');
    }

    // If this account has a password and we need to load it, do it now
    if (hasPassword && !_passwordCache.containsKey(accountId)) {
      print('[ACCOUNT_CARD] Attempting to fetch password for accountId="$accountId"');
      _fetchPasswordIfNeeded(account);
    } else if (!hasPassword) {
      print('[ACCOUNT_CARD] Account has no password (hasPassword=$hasPassword)');
    } else if (_passwordCache.containsKey(accountId)) {
      print('[ACCOUNT_CARD] Password already cached for accountId="$accountId"');
    }

    final passwordData = _passwordCache[accountId] ?? {};
    final passwordRaw = passwordData['Password'] ?? passwordData['password'] ?? '';
    
    // Check if password is prefixed with ACCOUNT_EXPIRED marker
    bool isAccountExpiredButHasPassword = false;
    String password = passwordRaw;
    if (passwordRaw.startsWith('ACCOUNT_EXPIRED:')) {
      // Parse the marker format: ACCOUNT_EXPIRED:expirationDate:actualPassword
      final parts = passwordRaw.split(':');
      if (parts.length >= 3) {
        // Rejoin remaining parts as password (in case password contains ':')
        password = parts.sublist(2).join(':');
        isAccountExpiredButHasPassword = true;
        print('[ACCOUNT_CARD] Password found for expired account, showing with warning');
      }
    }
    
    // Check if account_expired status is set but no password field override
    final isAccountExpiredStatus = passwordData['status'] == 'account_expired' && !isAccountExpiredButHasPassword;
    final isPasswordExpired = isAccountExpiredStatus;
    
    final isLoading =
        passwordData['status'] == 'loading' ||
        (hasPassword && password.isEmpty && 
         !passwordData.containsKey('error') &&
         passwordData['status'] != 'offline' &&
         !isPasswordExpired &&
         !isAccountExpiredButHasPassword);
    final showPassword = _passwordVisibility[accountId] ?? false;
    
    print('[ACCOUNT_CARD] Password status: isLoading=$isLoading, hasPassword=$hasPassword, password.isEmpty=${password.isEmpty}, passwordData.keys=${passwordData.keys.toList()}, isPasswordExpired=$isPasswordExpired');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: ExpansionTile(
        key: ValueKey('$accountKey:${_searchQuery.hashCode}'),
        initiallyExpanded: account['_searchMatched'] ?? false,
        title: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            if (isAccountExpired)
              Tooltip(
                message: 'Account expired on ${_formatDate(expirationDate)}',
                child: Icon(Icons.warning, size: 18, color: Colors.red.shade700),
              )
            else
              Icon(Icons.lock, size: 18, color: Colors.blue.shade700),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Entry Details Section
                Text(
                  'Entry Details',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 8),
                _buildDetailRow('Account Name', accountName),
                const SizedBox(height: 8),
                if (url.isNotEmpty)
                  _buildDetailRow('URL', url)
                else
                  _buildDetailRow('URL', '(Not set)'),
                const SizedBox(height: 8),
                if (notes.isNotEmpty)
                  _buildDetailRow('Notes', notes)
                else
                  _buildDetailRow('Notes', '(Not set)'),
                const SizedBox(height: 8),
                if (createdDate != null)
                  _buildDetailRow('Created', _formatDate(createdDate))
                else
                  _buildDetailRow('Created', '(Not available)'),
                const SizedBox(height: 8),
                if (expirationDate != null)
                  _buildDetailRow(
                    'Expiration',
                    _formatDate(expirationDate),
                    isWarning: isAccountExpired,
                  )
                else
                  _buildDetailRow('Expiration', '(No expiration)'),
                if (hasPassword)
                  const SizedBox(height: 16)
                else
                  const SizedBox(height: 0),
                if (hasPassword) ...[
                  if (isLoading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.blue.shade700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Loading password...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (password.isNotEmpty || isAccountExpiredButHasPassword) ...[
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            showPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 18,
                            color: Colors.blue.shade700,
                          ),
                          onPressed: () => _togglePasswordVisibility(accountId),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Icon(Icons.content_copy, size: 16, color: Colors.grey.shade600),
                          onPressed: () => _copyToClipboard(password),
                          padding: const EdgeInsets.all(0),
                          constraints: const BoxConstraints(),
                          tooltip: 'Copy to clipboard',
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Password',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: showPassword
                          ? RichText(
                              text: TextSpan(
                                children: _buildColoredPasswordSpans(password),
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            )
                          : Text(
                              _maskPassword(password),
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.blue.shade100),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildColorLegendItem('Numbers', Colors.orange),
                          _buildColorLegendItem('Special', Colors.blue),
                          _buildColorLegendItem('Upper', Colors.black),
                          _buildColorLegendItem('Lower', Colors.red),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ] else if (passwordData.containsKey('error')) ...[
                    Text(
                      'Error loading password: ${passwordData['error']}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade600,
                      ),
                    ),
                  ] else if (passwordData['status'] == 'offline') ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Colors.amber.shade700,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Password not available in offline mode. Connect online to retrieve.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.amber.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build account card with local visibility state (for dialogs)
  Widget _buildAccountCardWithLocalState(
    Map<String, dynamic> account,
    String accountKey,
    BuildContext dialogContext,
    bool localShowPassword,
    Function(bool) onShowPasswordChanged,
    Function(String) onCopied,
  ) {
    print('[ACCOUNT_CARD_LOCAL] Rendering account card with local state');
    
    final name = account['Name'] ?? 'Unknown';
    final accountName = account['AccountName'] ?? 'Unknown Account';
    final url = account['Url'] ?? '';
    final notes = account['Notes'] ?? '';
    final hasPassword = account['HasPassword'] ?? false;
    final accountId = account['Id']?.toString() ?? '';

    // Extract date information
    var createdDateStr = account['CreatedDate'] as String?;
    var expirationDateStr = account['ExpirationDate'] as String?;
    
    // If dates are missing and we're in offline mode, try to look them up from _accountsById
    if ((createdDateStr == null || expirationDateStr == null) && _isOfflineMode && accountId.isNotEmpty) {
      print('[ACCOUNT_CARD_LOCAL] Dates missing, looking up in _accountsById for accountId=$accountId');
      if (_accountsById.containsKey(accountId)) {
        final cachedAccountData = _accountsById[accountId];
        if (cachedAccountData != null) {
          if (createdDateStr == null) {
            createdDateStr = cachedAccountData['CreatedDate'] as String?;
            print('[ACCOUNT_CARD_LOCAL] Found CreatedDate from _accountsById: $createdDateStr');
          }
          if (expirationDateStr == null) {
            expirationDateStr = cachedAccountData['ExpirationDate'] as String?;
            print('[ACCOUNT_CARD_LOCAL] Found ExpirationDate from _accountsById: $expirationDateStr');
          }
        }
      }
    }
    
    final createdDate = createdDateStr != null ? DateTime.tryParse(createdDateStr) : null;
    final expirationDate = expirationDateStr != null ? DateTime.tryParse(expirationDateStr) : null;
    final isAccountExpired = expirationDate != null && DateTime.now().isAfter(expirationDate);

    // If this account has a password and we need to load it, do it now
    if (hasPassword && !_passwordCache.containsKey(accountId)) {
      _fetchPasswordIfNeeded(account);
    }

    final passwordData = _passwordCache[accountId] ?? {};
    final passwordRaw = passwordData['Password'] ?? passwordData['password'] ?? '';
    
    // Check if password is prefixed with ACCOUNT_EXPIRED marker
    bool isAccountExpiredButHasPassword = false;
    String password = passwordRaw;
    if (passwordRaw.startsWith('ACCOUNT_EXPIRED:')) {
      // Parse the marker format: ACCOUNT_EXPIRED:expirationDate:actualPassword
      final parts = passwordRaw.split(':');
      if (parts.length >= 3) {
        // Rejoin remaining parts as password (in case password contains ':')
        password = parts.sublist(2).join(':');
        isAccountExpiredButHasPassword = true;
        print('[ACCOUNT_CARD_LOCAL] Password found for expired account, showing with warning');
      }
    }
    
    // Check if account_expired status is set but no password field override
    final isAccountExpiredStatus = passwordData['status'] == 'account_expired' && !isAccountExpiredButHasPassword;
    final isPasswordExpired = isAccountExpiredStatus;
    
    final isLoading =
        passwordData['status'] == 'loading' ||
        (hasPassword && password.isEmpty && 
         !passwordData.containsKey('error') &&
         passwordData['status'] != 'offline' &&
         !isPasswordExpired &&
         !isAccountExpiredButHasPassword);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: ExpansionTile(
        key: ValueKey('$accountKey:${_searchQuery.hashCode}'),
        initiallyExpanded: true,
        title: Row(
          children: [
            Icon(Icons.lock, size: 18, color: Colors.blue.shade700),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Entry Details Section
                Text(
                  'Entry Details',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 8),
                _buildDetailRow('Account Name', accountName, onCopied: onCopied),
                const SizedBox(height: 8),
                if (url.isNotEmpty)
                  _buildDetailRow('URL', url, onCopied: onCopied)
                else
                  _buildDetailRow('URL', '(Not set)', onCopied: onCopied),
                const SizedBox(height: 8),
                if (notes.isNotEmpty)
                  _buildDetailRow('Notes', notes, onCopied: onCopied)
                else
                  _buildDetailRow('Notes', '(Not set)', onCopied: onCopied),
                const SizedBox(height: 8),
                if (createdDate != null)
                  _buildDetailRow('Created', _formatDate(createdDate), onCopied: onCopied)
                else
                  _buildDetailRow('Created', '(Not available)', onCopied: onCopied),
                const SizedBox(height: 8),
                if (expirationDate != null)
                  _buildDetailRow(
                    'Expiration',
                    _formatDate(expirationDate),
                    isWarning: isAccountExpired,
                    onCopied: onCopied,
                  )
                else
                  _buildDetailRow('Expiration', '(No expiration)', onCopied: onCopied),
                if (hasPassword)
                  const SizedBox(height: 16)
                else
                  const SizedBox(height: 0),
                if (hasPassword) ...[
                  if (isLoading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.blue.shade700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Loading password...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (password.isNotEmpty || isAccountExpiredButHasPassword) ...[
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            localShowPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 18,
                            color: Colors.blue.shade700,
                          ),
                          onPressed: () => onShowPasswordChanged(!localShowPassword),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Icon(Icons.content_copy, size: 16, color: Colors.grey.shade600),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: password));
                            onCopied('password');
                          },
                          padding: const EdgeInsets.all(0),
                          constraints: const BoxConstraints(),
                          tooltip: 'Copy to clipboard',
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Password',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: localShowPassword
                          ? RichText(
                              text: TextSpan(
                                children: _buildColoredPasswordSpans(password),
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            )
                          : Text(
                              _maskPassword(password),
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.blue.shade100),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildColorLegendItem('Numbers', Colors.orange),
                          _buildColorLegendItem('Special', Colors.blue),
                          _buildColorLegendItem('Upper', Colors.black),
                          _buildColorLegendItem('Lower', Colors.red),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ] else if (passwordData.containsKey('error')) ...[
                    Text(
                      'Error loading password: ${passwordData['error']}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade600,
                      ),
                    ),
                  ] else if (passwordData['status'] == 'offline') ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off, size: 18, color: Colors.orange.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Password not cached. Go online to view password.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build tree node widget (handles both folders and accounts)
  Widget _buildTreeNode(
    Map<String, dynamic> node,
    String nodeKey, {
    required int depth,
  }) {
    // Check if this is an account node
    if (_isAccount(node)) {
      // Handle offline account nodes (have _isOfflineAccount flag)
      if (node.containsKey('_isOfflineAccount') &&
          node['_isOfflineAccount'] == true) {
        print('[TREE] Rendering offline account node: id=${node['accountId']}, nodeKeys=${node.keys.toList()}');
        
        // Flatten accountData into node for display (merge nested fields to top level)
        final displayNode = Map<String, dynamic>.from(node);
        if (node.containsKey('accountData') && node['accountData'] is Map) {
          final accountData = node['accountData'] as Map<String, dynamic>;
          print('[TREE] BEFORE FLATTEN - displayNode.Url=${displayNode['Url']}, accountData.Url=${accountData['Url']}');
          print('[TREE] BEFORE FLATTEN - displayNode.Notes=${displayNode['Notes']}, accountData.Notes=${accountData['Notes']}');
          
          // Merge accountData fields into display node for easier access
          for (final entry in accountData.entries) {
            if (!displayNode.containsKey(entry.key)) {
              displayNode[entry.key] = entry.value;
            }
          }
          print('[TREE] AFTER FLATTEN - displayNode.Url=${displayNode['Url']}, displayNode.Notes=${displayNode['Notes']}');
          print('[TREE] Flattened accountData for offline node ${node['accountId']}: merged fields from accountData');
        }
        
        // Ensure 'Id' field is set for password cache lookup consistency
        if (!displayNode.containsKey('Id') && node.containsKey('accountId')) {
          displayNode['Id'] = node['accountId'];
          print('[TREE] Set displayNode[\'Id\'] = ${node['accountId']} (from accountId)');
        }
        
        return ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 300, maxWidth: 600),
          child: Padding(
            padding: EdgeInsets.only(left: depth * 8.0),
            child: _buildAccountCard(displayNode, 'tree_account_$nodeKey'),
          ),
        );
      } else {
        // Handle online account nodes (from API, no _isOfflineAccount flag)
        print('[TREE] Rendering online account node: id=${node['Id'] ?? node['id']}, nodeKeys=${node.keys.toList()}');
        
        // For online accounts, merge tree node with full account data from API
        final displayNode = Map<String, dynamic>.from(node);
        
        // Extract account ID (can come from different keys - including enterpriseAccountId for nested accounts)
        String? accountId = node['Id']?.toString() ?? 
                            node['id']?.toString() ?? 
                            node['accountId']?.toString() ??
                            node['enterpriseAccountId']?.toString();
        
        print('[TREE] Online account merge attempt: accountId=$accountId, node.keys=${node.keys.toList()}, _accountsData=${_accountsData != null ? "SET" : "NULL"}, accounts.count=${_accountsData?.accounts.length ?? 0}');
        
        if (accountId != null && _accountsData != null) {
          try {
            // Find full account data in API response
            print('[TREE] Searching in ${_accountsData!.accounts.length} accounts for accountId=$accountId');
            final fullAccountData = _accountsData!.accounts
                .cast<Map<String, dynamic>>()
                .firstWhere(
                  (acc) {
                    final accId = acc['Id']?.toString() ?? acc['id']?.toString();
                    final matches = accId == accountId;
                    if (!matches) {
                      print('[TREE] Comparing: accId="$accId" vs target="$accountId" - NO MATCH');
                    }
                    return matches;
                  },
                  orElse: () => <String, dynamic>{},
                );
            
            if (fullAccountData.isNotEmpty) {
              print('[TREE] ✓ Found full account data for online account: id=$accountId, name=${fullAccountData['Name']}');
              
              // Merge all fields from full account data into display node
              for (final entry in fullAccountData.entries) {
                if (!displayNode.containsKey(entry.key)) {
                  displayNode[entry.key] = entry.value;
                }
              }
              
              print('[TREE] Merged online account data: Name=${fullAccountData['Name']}, CreatedDate=${fullAccountData['CreatedDate']}, ExpirationDate=${fullAccountData['ExpirationDate']}');
            } else {
              print('[TREE] ✗ Account not found in _accountsData.accounts for id=$accountId');
            }
          } catch (e) {
            print('[TREE] ✗ Error merging online account data: $e');
          }
        } else {
          print('[TREE] Skipping merge: accountId=${accountId != null ? "SET" : "NULL"}, _accountsData=${_accountsData != null ? "SET" : "NULL"}');
        }
        
        // Ensure 'Id' field is set for password cache lookup
        if (!displayNode.containsKey('Id') && accountId != null) {
          displayNode['Id'] = accountId;
          print('[TREE] Set displayNode[\'Id\'] = $accountId (from extracted accountId) for online account');
        }
        
        print('[TREE] Final displayNode before rendering: Id=${displayNode['Id']}, Name=${displayNode['Name']}, CreatedDate=${displayNode['CreatedDate']}, ExpirationDate=${displayNode['ExpirationDate']}');
        
        return ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 300, maxWidth: 600),
          child: Padding(
            padding: EdgeInsets.only(left: depth * 8.0),
            child: _buildAccountCard(displayNode, 'tree_account_$nodeKey'),
          ),
        );
      }
    }

    // Check if this is a folder node
    if (_isFolder(node)) {
      // Extract folder name with multiple fallbacks
      final rawFolderName = node['folderName'];
      var folderName = (rawFolderName ?? '').toString().trim();

      // If still empty or "Unknown", try other fields
      if (folderName.isEmpty || folderName == 'Unknown') {
        for (final key in [
          'Folder',
          'folder',
          'name',
          'Name',
          'title',
          'Title',
        ]) {
          if (node[key] != null) {
            final val = node[key].toString().trim();
            if (val.isNotEmpty && val != 'Unknown') {
              folderName = val;
              break;
            }
          }
        }
      }

      final displayName = folderName.isNotEmpty ? folderName : 'Unnamed Folder';
      final folderId = node['folderId'] ?? 'unknown';
      final children = _getNodeChildren(node);

      print(
        '[TREE] Rendering folder node: rawName=$rawFolderName, displayName=$displayName, id=$folderId, children.length=${children.length}',
      );

      // For folders with no children, still show them
      return ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 300, maxWidth: 600),
        child: Container(
          margin: EdgeInsets.only(
            left: depth * 2.0,
            right: 4,
            top: 4,
            bottom: 4,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade200),
            borderRadius: BorderRadius.circular(8),
            color: Colors.grey.shade50,
          ),
          child: children.isEmpty
              ? ExpansionTile(
                  key: ValueKey('$nodeKey:${_searchQuery.hashCode}'),
                  initiallyExpanded: node['_searchMatched'] ?? false,
                  leading: Icon(
                    Icons.folder,
                    size: 20,
                    color: Colors.orange.shade600,
                  ),
                  title: Text(
                    displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text(
                    '(empty)',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  children: const [],
                )
              : ExpansionTile(
                  key: ValueKey('$nodeKey:${_searchQuery.hashCode}'),
                  initiallyExpanded: node['_searchMatched'] ?? false,
                  leading: Icon(
                    Icons.folder,
                    size: 20,
                    color: Colors.orange.shade600,
                  ),
                  title: Text(
                    displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${children.length} item(s)',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ...children.asMap().entries.map((entry) {
                            print(
                              '[TREE] Processing child ${entry.key} of folder $folderName',
                            );
                            return _buildTreeNode(
                              entry.value,
                              '${nodeKey}_child_${entry.key}',
                              depth: depth + 1,
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      );
    }

    // Unknown node type
    print('[TREE] Unknown node type: $node');
    return SizedBox.shrink();
  }

  Widget _buildDetailRow(String label, String value, {Function(String)? onCopied, bool isWarning = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(Icons.content_copy, size: 16, color: Colors.grey.shade600),
              onPressed: () {
                _copyToClipboard(value);
                onCopied?.call(label);
              },
              padding: const EdgeInsets.all(0),
              constraints: const BoxConstraints(),
              tooltip: 'Copy to clipboard',
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isWarning ? Colors.red.shade700 : Colors.grey.shade600,
              ),
            ),
            if (isWarning) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.warning,
                size: 14,
                color: Colors.red.shade700,
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isWarning ? Colors.red.shade50 : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: isWarning ? Colors.red.shade200 : Colors.grey.shade200),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: isWarning ? Colors.red.shade700 : Colors.black,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  String _maskPassword(String password) {
    if (password.isEmpty) return '';
    return '•' * password.length;
  }

  String _formatDate(DateTime date) {
    // Format: "March 24, 2026 at 5:00 PM"
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} at ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  List<TextSpan> _buildColoredPasswordSpans(String password) {
    final List<TextSpan> spans = [];
    const specialChars = '!@#\$%^&*()_+-=[]{}:;<>,.?/\\|`~"\'';

    for (int i = 0; i < password.length; i++) {
      final char = password[i];
      Color charColor;

      // Determine color based on character type
      if (RegExp(r'^[0-9]$').hasMatch(char)) {
        // Numbers: orange
        charColor = Colors.orange;
      } else if (RegExp(r'^[A-Z]$').hasMatch(char)) {
        // Upper case: black
        charColor = Colors.black;
      } else if (RegExp(r'^[a-z]$').hasMatch(char)) {
        // Lower case: red
        charColor = Colors.red;
      } else if (specialChars.contains(char)) {
        // Special characters: blue
        charColor = Colors.blue;
      } else {
        // Unknown (spaces, etc): grey
        charColor = Colors.grey;
      }

      spans.add(
        TextSpan(
          text: char,
          style: TextStyle(
            color: charColor,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      );
    }

    return spans;
  }

  Widget _buildColorLegendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  /// Build the content widget based on loading/error state
  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.info_outline, size: 64, color: Colors.orange.shade400),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      );
    }

    if (_accountsData == null &&
        !_isOfflineMode &&
        _folders.isEmpty &&
        _accountsData == null) {
      return const Center(child: Text('No accounts found'));
    }

    // Get tree structure based on mode and data availability
    // Prefer offline tree if in offline mode, prefer online tree if in online mode
    List<Map<String, dynamic>> treeStructure = [];

    if (_isOfflineMode) {
      // In offline mode, use offline tree structure
      if (_folders.isNotEmpty) {
        treeStructure = _buildOfflineTreeStructure();
        print(
          '[CONTENT] Offline mode: rendered ${treeStructure.length} root nodes from _folders',
        );
      } else {
        print('[CONTENT] Offline mode but _folders is empty');
      }
    } else {
      // In online mode, use API tree structure (don't use offline _folders)
      if (_accountsData != null) {
        treeStructure = _buildTreestructure();
        print(
          '[CONTENT] Online mode: rendered ${treeStructure.length} root nodes from API tree',
        );
      } else if (_accountsData != null) {
        // Use current data for display
        treeStructure = _buildTreestructure();
        print('[CONTENT] Online mode (no online data): using cached data');
      }
    }

    if (treeStructure.isEmpty) {
      return const Center(child: Text('No account data available'));
    }

    // Apply search filter if query is not empty
    if (_searchQuery.isNotEmpty) {
      treeStructure = _filterTreeStructure(treeStructure);
      
      if (treeStructure.isEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search_off, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text(
                'No accounts match "$_searchQuery"',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              ),
            ],
          ),
        );
      }
    }

    try {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Render tree nodes from preferences or offline storage
                    ...treeStructure.asMap().entries.map((entry) {
                      final rootNode = entry.value;
                      try {
                        return _buildTreeNode(
                          rootNode,
                          'root_node_${entry.key}',
                          depth: 0,
                        );
                      } catch (e) {
                        print('[ERROR] Failed to render tree node: $e');
                        return Center(child: Text('Error rendering node: $e'));
                      }
                    }),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      print('[ERROR] Failed to build tree content: $e');
      return Center(child: Text('Error loading tree: $e'));
    }
  }

  Widget _buildTreeViewSection() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: ExpansionTile(
        initiallyExpanded: _treeViewExpanded,
        onExpansionChanged: (expanded) {
          setState(() {
            _treeViewExpanded = expanded;
          });
        },
        title: Row(
          children: [
            const Icon(Icons.folder_open, size: 20),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Tree View',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: _buildContent(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Offline/Online toggle
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey[100],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _isOfflineMode ? Icons.cloud_off : Icons.cloud,
                      color: _isOfflineMode ? Colors.orange : Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isOfflineMode ? 'Offline Mode' : 'Online Mode',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: !_isOfflineMode,
                  onChanged: _isLoading
                      ? null
                      : (value) {
                          _toggleOfflineMode(!value);
                        },
                ),
              ],
            ),
          ),
          // Search field
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search accounts...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
          // View Mode toggle
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey[100],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _isListViewMode ? Icons.list : Icons.account_tree,
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isListViewMode ? 'List View' : 'Tree View',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: _isListViewMode,
                  onChanged: (value) {
                    _toggleViewMode();
                  },
                ),
              ],
            ),
          ),
          // Content - show list or tree based on mode
          Expanded(
            child: _isListViewMode
                ? SingleChildScrollView(child: _buildAccountListSection())
                : SingleChildScrollView(child: _buildTreeViewSection()),
          ),
        ],
      ),
    );
  }
}
