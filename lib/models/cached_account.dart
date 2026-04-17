import 'dart:convert';

/// Account model for storing fetched accounts in database
class CachedAccount {
  final String id; // Account ID from API
  final String username; // Username of logged-in user
  final String name; // Account name (display name)
  final String? accountName; // Alternative account name field
  final String? url;
  final String? notes;
  final bool hasPassword;
  final String? endpoint; // Which endpoint it came from
  final DateTime cachedAt;
  final Map<String, dynamic> rawData; // Store full account data from API

  CachedAccount({
    required this.id,
    required this.username,
    required this.name,
    this.accountName,
    this.url,
    this.notes,
    this.hasPassword = false,
    this.endpoint,
    required this.cachedAt,
    required this.rawData,
  });

  /// Convert to database map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'name': name,
      'account_name': accountName,
      'url': url,
      'notes': notes,
      'has_password': hasPassword ? 1 : 0,
      'endpoint': endpoint,
      'cached_at': cachedAt.toIso8601String(),
      'raw_data': jsonEncode(rawData),
    };
  }

  /// Create from database map
  factory CachedAccount.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> rawData = {};
    final rawDataJson = map['raw_data'] as String?;
    if (rawDataJson != null && rawDataJson.isNotEmpty) {
      try {
        rawData = jsonDecode(rawDataJson) as Map<String, dynamic>;
      } catch (e) {
        print('Error decoding raw_data: $e');
      }
    }

    return CachedAccount(
      id: map['id'] as String,
      username: map['username'] as String,
      name: map['name'] as String,
      accountName: map['account_name'] as String?,
      url: map['url'] as String?,
      notes: map['notes'] as String?,
      hasPassword: (map['has_password'] as int?) == 1,
      endpoint: map['endpoint'] as String?,
      cachedAt: DateTime.parse(map['cached_at'] as String),
      rawData: rawData,
    );
  }

  /// Create from API account data
  factory CachedAccount.fromApiData(
    Map<String, dynamic> apiData,
    String username,
    String endpoint,
  ) {
    final id = (apiData['Id'] ?? apiData['id'] ?? '').toString();
    final name = apiData['Name'] ?? apiData['name'] ?? 'Unknown';
    final accountName = apiData['AccountName'] ?? apiData['accountName'];
    final url = apiData['Url'] ?? apiData['url'];
    final notes = apiData['Notes'] ?? apiData['notes'];
    final hasPassword = apiData['HasPassword'] ?? apiData['hasPassword'] ?? false;

    return CachedAccount(
      id: id,
      username: username,
      name: name.toString(),
      accountName: accountName?.toString(),
      url: url?.toString(),
      notes: notes?.toString(),
      hasPassword: hasPassword == true || hasPassword == 1,
      endpoint: endpoint,
      cachedAt: DateTime.now(),
      rawData: apiData,
    );
  }

  @override
  String toString() =>
      'CachedAccount(id=$id, name=$name, username=$username, endpoint=$endpoint)';
}
