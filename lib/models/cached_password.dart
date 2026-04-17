class CachedPassword {
  final int id;
  final String username;
  final String accountId;
  final String accountName;
  final String encryptedPassword;
  final DateTime cachedAt;
  final DateTime? expiresAt; // Cache expiry (when we stop using the cached password)
  final DateTime? accountExpirationDate; // Account's actual expiration date from API
  final DateTime? accountCreatedDate; // Account's creation date from API

  CachedPassword({
    required this.id,
    required this.username,
    required this.accountId,
    required this.accountName,
    required this.encryptedPassword,
    required this.cachedAt,
    this.expiresAt,
    this.accountExpirationDate,
    this.accountCreatedDate,
  });

  /// Check if the account itself has expired (based on account's ExpirationDate)
  bool get isAccountExpired => accountExpirationDate != null && DateTime.now().isAfter(accountExpirationDate!);

  /// Check if the cached password is still valid (cache expiry, not account expiry)
  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Check if the cached password is fresh (less than 1 hour old)
  bool get isFresh {
    final age = DateTime.now().difference(cachedAt);
    return age.inHours < 1;
  }

  /// Convert CachedPassword to a Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'account_id': accountId,
      'account_name': accountName,
      'encrypted_password': encryptedPassword,
      'cached_at': cachedAt.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
      'account_expiration_date': accountExpirationDate?.toIso8601String(),
      'account_created_date': accountCreatedDate?.toIso8601String(),
    };
  }

  /// Create a CachedPassword from a database Map
  factory CachedPassword.fromMap(Map<String, dynamic> map) {
    return CachedPassword(
      id: map['id'] as int,
      username: map['username'] as String,
      accountId: map['account_id'] as String,
      accountName: map['account_name'] as String,
      encryptedPassword: map['encrypted_password'] as String,
      cachedAt: DateTime.parse(map['cached_at'] as String),
      expiresAt: map['expires_at'] != null
          ? DateTime.parse(map['expires_at'] as String)
          : null,
      accountExpirationDate: map['account_expiration_date'] != null
          ? DateTime.parse(map['account_expiration_date'] as String)
          : null,
      accountCreatedDate: map['account_created_date'] != null
          ? DateTime.parse(map['account_created_date'] as String)
          : null,
    );
  }

  /// Create a copy with modifications
  CachedPassword copyWith({
    int? id,
    String? username,
    String? accountId,
    String? accountName,
    String? encryptedPassword,
    DateTime? cachedAt,
    DateTime? expiresAt,
  }) {
    return CachedPassword(
      id: id ?? this.id,
      username: username ?? this.username,
      accountId: accountId ?? this.accountId,
      accountName: accountName ?? this.accountName,
      encryptedPassword: encryptedPassword ?? this.encryptedPassword,
      cachedAt: cachedAt ?? this.cachedAt,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  @override
  String toString() =>
      'CachedPassword(username: $username, accountId: $accountId, '
      'accountName: $accountName, cached: ${isFresh ? "fresh" : "stale"})';
}
