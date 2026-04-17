import 'dart:convert';

class AccountTree {
  final int id;
  final String username;
  final String name;
  final String? parentId;
  final String? accountId;
  final bool isFolder;
  final int? depth;
  final DateTime syncedAt;
  final Map<String, dynamic>? accountData; // Store full account details for offline access
  final int? sequenceOrder; // Preserve original order from API

  AccountTree({
    required this.id,
    required this.username,
    required this.name,
    this.parentId,
    this.accountId,
    this.isFolder = true,
    this.depth,
    required this.syncedAt,
    this.accountData,
    this.sequenceOrder,
  });

  /// Convert AccountTree to a Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'name': name,
      'parent_id': parentId,
      'account_id': accountId,
      'is_folder': isFolder ? 1 : 0,
      'depth': depth,
      'synced_at': syncedAt.toIso8601String(),
      'account_data': accountData != null ? jsonEncode(accountData) : null,
      'sequence_order': sequenceOrder,
    };
  }

  /// Create an AccountTree from a database Map
  factory AccountTree.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic>? accountData;
    final accountDataJson = map['account_data'] as String?;
    if (accountDataJson != null && accountDataJson.isNotEmpty) {
      try {
        accountData = jsonDecode(accountDataJson) as Map<String, dynamic>;
      } catch (e) {
        print('Error decoding account_data: $e');
      }
    }

    return AccountTree(
      id: map['id'] as int,
      username: map['username'] as String,
      name: map['name'] as String,
      parentId: map['parent_id'] as String?,
      accountId: map['account_id'] as String?,
      isFolder: (map['is_folder'] as int) == 1,
      depth: map['depth'] as int?,
      syncedAt: DateTime.parse(map['synced_at'] as String),
      accountData: accountData,
      sequenceOrder: map['sequence_order'] as int?,
    );
  }

  /// Create from API response (folder/account object)
  factory AccountTree.fromApiResponse(
    String username,
    Map<String, dynamic> data, {
    String? parentId,
    int? depth,
  }) {
    final name = data['Name'] as String? ?? 'Unknown';
    final id = data['ID'] as String? ?? '';
    final isFolder = data['Children'] != null;

    return AccountTree(
      id: id.hashCode,
      username: username,
      name: name,
      parentId: parentId,
      accountId: isFolder ? null : id,
      isFolder: isFolder,
      depth: depth ?? 0,
      syncedAt: DateTime.now(),
    );
  }

  @override
  String toString() =>
      'AccountTree(username: $username, name: $name, isFolder: $isFolder, depth: $depth)';
}
