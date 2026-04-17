class User {
  final String username;
  final String passwordHash;
  final String? serverAddress;
  final bool biometricEnabled;
  final bool isOffline;
  final DateTime createdAt;
  final DateTime? lastLogin;

  User({
    required this.username,
    required this.passwordHash,
    this.serverAddress,
    this.biometricEnabled = false,
    this.isOffline = true,
    required this.createdAt,
    this.lastLogin,
  });

  /// Convert User to a Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'username': username,
      'password_hash': passwordHash,
      'server_address': serverAddress,
      'biometric_enabled': biometricEnabled ? 1 : 0,
      'is_offline': isOffline ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'last_login': lastLogin?.toIso8601String(),
    };
  }

  /// Create a User from a database Map
  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      username: map['username'] as String,
      passwordHash: map['password_hash'] as String,
      serverAddress: map['server_address'] as String?,
      biometricEnabled: (map['biometric_enabled'] as int) == 1,
      isOffline: (map['is_offline'] as int?) == 1 ? true : true,
      createdAt: DateTime.parse(map['created_at'] as String),
      lastLogin: map['last_login'] != null
          ? DateTime.parse(map['last_login'] as String)
          : null,
    );
  }

  /// Create a copy with modifications
  User copyWith({
    String? username,
    String? passwordHash,
    String? serverAddress,
    bool? biometricEnabled,
    bool? isOffline,
    DateTime? createdAt,
    DateTime? lastLogin,
  }) {
    return User(
      username: username ?? this.username,
      passwordHash: passwordHash ?? this.passwordHash,
      serverAddress: serverAddress ?? this.serverAddress,
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
      isOffline: isOffline ?? this.isOffline,
      createdAt: createdAt ?? this.createdAt,
      lastLogin: lastLogin ?? this.lastLogin,
    );
  }

  @override
  String toString() =>
      'User(username: $username, serverAddress: $serverAddress, '
      'biometricEnabled: $biometricEnabled, isOffline: $isOffline, createdAt: $createdAt, lastLogin: $lastLogin)';
}
