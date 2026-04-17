import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:io';
import '../models/user.dart';
import '../models/account_tree.dart';
import '../models/cached_password.dart';
import '../models/cached_account.dart';

class DatabaseService {
  static const String _oldDbName = 'sgpwmobile.db';
  static const int _dbVersion = 5;

  static const String usersTable = 'users';
  static const String accountTreeTable = 'account_tree';
  static const String cachedPasswordsTable = 'cached_passwords';
  static const String cachedAccountsTable = 'cached_accounts';

  // Map to hold per-user database connections
  static final Map<String, Database> _databases = {};
  static bool _migrationChecked = false;

  /// Get or initialize database for a specific user
  Future<Database> getDatabase(String username) async {
    // Check and run migration on first app access
    if (!_migrationChecked) {
      _migrationChecked = true;
      await _checkAndMigrateOldDatabase();
    }

    if (_databases.containsKey(username)) {
      print('[DATABASE] ✓ Returning cached database connection for user=$username');
      return _databases[username]!;
    }
    print('[DATABASE] 🔗 First access - initializing database for user=$username');
    final db = await _initDatabaseForUser(username);
    _databases[username] = db;
    return db;
  }

  /// Close database connection for a specific user
  Future<void> closeDatabase(String username) async {
    if (_databases.containsKey(username)) {
      try {
        await _databases[username]!.close();
        _databases.remove(username);
        print('[DATABASE] 🔒 Closed and removed database connection for user=$username');
      } catch (e) {
        print('[DATABASE] ⚠️  Error closing database for $username: $e');
      }
    }
  }

  /// Check if old shared database exists and migrate data to per-user databases
  Future<void> _checkAndMigrateOldDatabase() async {
    try {
      final databasePath = await getDatabasesPath();
      final oldPath = join(databasePath, _oldDbName);
      final oldDbFile = File(oldPath);

      if (!oldDbFile.existsSync()) {
        print('[DATABASE] ✅ No old database found - fresh start');
        return;
      }

      print('[DATABASE] 📦 OLD DATABASE DETECTED - Starting migration process...');

      // Open old database
      final oldDb = await openDatabase(
        oldPath,
        version: _dbVersion,
        onCreate: _createTables,
        onUpgrade: _upgradeTables,
      );
      await oldDb.execute('PRAGMA foreign_keys = ON');

      // Read all users from old database
      final userMaps = await oldDb.query(usersTable);
      print('[DATABASE] 📋 Found ${userMaps.length} users in old database');

      if (userMaps.isEmpty) {
        // No users in old database, just delete it
        print('[DATABASE] ⚠️  No users in old database - deleting...');
        await oldDb.close();
        await deleteDatabase(oldPath);
        print('[DATABASE] ✅ Old empty database deleted');
        return;
      }

      // Migrate each user's data
      for (final userMap in userMaps) {
        final username = userMap['username'] as String;
        await _migrateUserData(oldDb, username);
      }

      // Close and delete old database
      await oldDb.close();
      try {
        await deleteDatabase(oldPath);
        print('[DATABASE] ✅ Old shared database deleted successfully');
      } catch (e) {
        print('[DATABASE] ⚠️  Could not delete old database: $e');
      }
    } catch (e) {
      print('[DATABASE] ❌ Migration error: $e');
      // Continue anyway - old database will remain but new per-user databases are created
    }
  }

  /// Migrate a single user's data to their per-user database
  Future<void> _migrateUserData(Database oldDb, String username) async {
    try {
      print('[DATABASE] 📦 Migrating user: $username');

      // Create new database for this user
      final newDb = await _initDatabaseForUser(username);

      // Migrate users table
      final userData = await oldDb.query(
        usersTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      if (userData.isNotEmpty) {
        await newDb.insert(
          usersTable,
          userData.first,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        print('[DATABASE]   ✓ User record migrated: $username');
      }

      // Migrate account_tree table
      final treeData = await oldDb.query(
        accountTreeTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      for (final row in treeData) {
        await newDb.insert(
          accountTreeTable,
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      print('[DATABASE]   ✓ Account tree migrated: ${treeData.length} nodes');

      // Migrate cached_passwords table
      final passwordData = await oldDb.query(
        cachedPasswordsTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      for (final row in passwordData) {
        await newDb.insert(
          cachedPasswordsTable,
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      print('[DATABASE]   ✓ Cached passwords migrated: ${passwordData.length} passwords');

      // Migrate cached_accounts table
      final accountData = await oldDb.query(
        cachedAccountsTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      for (final row in accountData) {
        await newDb.insert(
          cachedAccountsTable,
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      print('[DATABASE]   ✓ Cached accounts migrated: ${accountData.length} accounts');

      await newDb.close();
      print('[DATABASE] ✅ Migration complete for user: $username');
    } catch (e) {
      print('[DATABASE] ❌ Error migrating user $username: $e');
    }
  }

  /// Initialize database for a specific user
  Future<Database> _initDatabaseForUser(String username) async {
    final databasePath = await getDatabasesPath();
    final dbFileName = 'sgpwmobile_$username.db';
    final path = join(databasePath, dbFileName);

    print('[DATABASE] 🔧 Opening database: $dbFileName');

    // Try to open database, if it fails due to schema issues, delete and recreate
    try {
      Database db = await openDatabase(
        path,
        version: _dbVersion,
        onCreate: _createTables,
        onUpgrade: _upgradeTables,
      );

      // CRITICAL: Enable FOREIGN KEY constraints (SQLite disabled by default)
      await db.execute('PRAGMA foreign_keys = ON');
      print('[DATABASE] ✅ FOREIGN KEY constraints ENABLED for user=$username');

      // Verify critical tables and columns exist
      final isValid = await _checkTableExists(db);
      if (!isValid) {
        print('[DATABASE] Schema validation failed for user=$username! Deleting and recreating database...');
        await db.close();
        try {
          await deleteDatabase(path);
          print('[DATABASE] Old database deleted for user=$username');
        } catch (e) {
          print('[DATABASE] Error deleting old database for $username: $e');
        }
        // Recursively open database which will trigger onCreate
        return _initDatabaseForUser(username);
      }

      print('[DATABASE] 🔗 Opened database: $dbFileName for user=$username');
      return db;
    } catch (e) {
      print('[DATABASE] Error opening database for user=$username: $e. Deleting and recreating...');
      try {
        await deleteDatabase(path);
        print('[DATABASE] Old database deleted due to error for user=$username');
      } catch (deleteError) {
        print('[DATABASE] Error deleting old database for $username: $deleteError');
      }

      // Retry opening with fresh database
      final db = await openDatabase(
        path,
        version: _dbVersion,
        onCreate: _createTables,
        onUpgrade: _upgradeTables,
      );
      
      // CRITICAL: Enable FOREIGN KEY constraints (SQLite disabled by default)
      await db.execute('PRAGMA foreign_keys = ON');
      print('[DATABASE] ✅ FOREIGN KEY constraints ENABLED after error recovery for user=$username');
      
      return db;
    }
  }

  /// Deprecated: Use getDatabase(username) instead
  /// This getter is only for backwards compatibility
  @deprecated
  Future<Database> get database async {
    throw Exception(
      'DatabaseService.database getter is deprecated. '
      'Use getDatabase(username) instead to get user-specific database.'
    );
  }

  /// Check if critical tables and columns exist in the database
  Future<bool> _checkTableExists(Database db) async {
    try {
      // Check if cached_accounts table exists
      final cachedAccountsExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='$cachedAccountsTable'");
      if (cachedAccountsExists.isEmpty) {
        print('Table $cachedAccountsTable missing!');
        return false;
      }

      // Check if account_data column exists in account_tree table
      try {
        final columnCheck = await db.rawQuery(
            "PRAGMA table_info($accountTreeTable)");
        
        // PRAGMA table_info returns rows with: cid, name, type, notnull, dflt_value, pk
        final hasAccountDataColumn = columnCheck.any((col) {
          // col is a Map<String, dynamic> with keys like 'name', 'type', etc.
          final colName = col['name'];
          return colName == 'account_data';
        });
        
        if (!hasAccountDataColumn) {
          print('Column account_data missing from $accountTreeTable table - schema mismatch!');
          return false;
        }
      } catch (pragmaError) {
        print('Error checking columns with PRAGMA: $pragmaError');
        // If PRAGMA fails, assume schema is invalid
        return false;
      }

      return true;
    } catch (e) {
      print('Error checking database schema: $e');
      return false;
    }
  }

  /// Create all tables
  Future<void> _createTables(Database db, int version) async {
    // Users table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $usersTable (
        username TEXT PRIMARY KEY,
        password_hash TEXT NOT NULL,
        server_address TEXT,
        biometric_enabled INTEGER DEFAULT 0,
        is_offline INTEGER DEFAULT 1,
        created_at TEXT NOT NULL,
        last_login TEXT
      )
    ''');

    // Account tree table (hierarchy of folders and accounts)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $accountTreeTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL,
        name TEXT NOT NULL,
        parent_id TEXT,
        account_id TEXT,
        is_folder INTEGER DEFAULT 1,
        depth INTEGER,
        synced_at TEXT NOT NULL,
        account_data TEXT,
        sequence_order INTEGER,
        FOREIGN KEY (username) REFERENCES $usersTable(username) ON DELETE CASCADE,
        UNIQUE (username, name, parent_id)
      )
    ''');

    // Cached passwords table (per-user encrypted password cache)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $cachedPasswordsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL,
        account_id TEXT NOT NULL,
        account_name TEXT NOT NULL,
        encrypted_password TEXT NOT NULL,
        cached_at TEXT NOT NULL,
        expires_at TEXT,
        account_expiration_date TEXT,
        account_created_date TEXT,
        FOREIGN KEY (username) REFERENCES $usersTable(username) ON DELETE CASCADE,
        UNIQUE (username, account_id)
      )
    ''');

    // Cached accounts table (accounts from API for offline access)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $cachedAccountsTable (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL,
        name TEXT NOT NULL,
        account_name TEXT,
        url TEXT,
        notes TEXT,
        has_password INTEGER DEFAULT 0,
        endpoint TEXT,
        cached_at TEXT NOT NULL,
        raw_data TEXT,
        FOREIGN KEY (username) REFERENCES $usersTable(username) ON DELETE CASCADE,
        UNIQUE (username, id)
      )
    ''');

    // Create indexes for faster lookups
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_account_tree_username ON $accountTreeTable(username)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_cached_passwords_username ON $cachedPasswordsTable(username)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_cached_accounts_username ON $cachedAccountsTable(username)');
  }

  /// Upgrade database schema
  Future<void> _upgradeTables(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add is_offline column to users table if it doesn't exist
      try {
        await db.execute('ALTER TABLE $usersTable ADD COLUMN is_offline INTEGER DEFAULT 1');
        print('Database migrated: Added is_offline column to $usersTable');
      } catch (e) {
        // Column might already exist, ignore error
        print('Migration note: $e');
      }
    }

    if (oldVersion < 3) {
      // Add account_data column to account_tree table for storing full account details offline
      try {
        await db.execute(
            'ALTER TABLE $accountTreeTable ADD COLUMN account_data TEXT');
        print('Database migrated: Added account_data column to $accountTreeTable');
      } catch (e) {
        // Column might already exist, ignore error
        print('Migration note: $e');
      }

      // Create cached_accounts table if it doesn't exist
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $cachedAccountsTable (
            id TEXT PRIMARY KEY,
            username TEXT NOT NULL,
            name TEXT NOT NULL,
            account_name TEXT,
            url TEXT,
            notes TEXT,
            has_password INTEGER DEFAULT 0,
            endpoint TEXT,
            cached_at TEXT NOT NULL,
            raw_data TEXT,
            FOREIGN KEY (username) REFERENCES $usersTable(username) ON DELETE CASCADE,
            UNIQUE (username, id)
          )
        ''');
        print('Database migrated: Created $cachedAccountsTable table');
      } catch (e) {
        print('Migration note: $e');
      }

      // Create index for cached_accounts if it doesn't exist
      try {
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_cached_accounts_username ON $cachedAccountsTable(username)');
      } catch (e) {
        print('Migration note: $e');
      }
    }

    if (oldVersion < 4) {
      // Add sequence_order column to preserve original tree order from API
      try {
        await db.execute(
            'ALTER TABLE $accountTreeTable ADD COLUMN sequence_order INTEGER');
        print('Database migrated: Added sequence_order column to $accountTreeTable');
      } catch (e) {
        // Column might already exist, ignore error
        print('Migration note: $e');
      }
    }

    if (oldVersion < 5) {
      // Add date columns to cached_passwords table for account expiration tracking
      try {
        await db.execute(
            'ALTER TABLE $cachedPasswordsTable ADD COLUMN account_expiration_date TEXT');
        print('Database migrated: Added account_expiration_date column to $cachedPasswordsTable');
      } catch (e) {
        print('Migration note (account_expiration_date): $e');
      }

      try {
        await db.execute(
            'ALTER TABLE $cachedPasswordsTable ADD COLUMN account_created_date TEXT');
        print('Database migrated: Added account_created_date column to $cachedPasswordsTable');
      } catch (e) {
        print('Migration note (account_created_date): $e');
      }
    }
  }

  // ===================== User Operations =====================

  /// Insert a new user
  Future<void> insertUser(User user) async {
    final db = await getDatabase(user.username);
    await db.insert(
      usersTable,
      user.toMap(),
      conflictAlgorithm: ConflictAlgorithm.fail,
    );
  }

  /// Get a user by username
  Future<User?> getUser(String username) async {
    final db = await getDatabase(username);
    final result = await db.query(
      usersTable,
      where: 'username = ?',
      whereArgs: [username],
    );

    if (result.isEmpty) {
      return null;
    }
    return User.fromMap(result.first);
  }

  /// Get all users
  Future<List<User>> getAllUsers() async {
    // Note: This queries ALL user records, which would be across multiple databases
    // This method should not be used in per-user database architecture
    throw UnimplementedError(
      'getAllUsers() is not supported in per-user database architecture. '
      'Use database queries specific to a single user.'
    );
  }

  /// Update a user
  Future<void> updateUser(User user) async {
    final db = await getDatabase(user.username);
    await db.update(
      usersTable,
      user.toMap(),
      where: 'username = ?',
      whereArgs: [user.username],
    );
  }

  /// Delete a user and all associated data
  Future<void> deleteUser(String username) async {
    final db = await getDatabase(username);
    await db.transaction((txn) async {
      // Delete cascades to account_tree and cached_passwords via foreign key
      await txn.delete(
        usersTable,
        where: 'username = ?',
        whereArgs: [username],
      );
    });
  }

  /// Update user's last login time
  Future<void> updateLastLogin(String username) async {
    final db = await getDatabase(username);
    await db.update(
      usersTable,
      {'last_login': DateTime.now().toIso8601String()},
      where: 'username = ?',
      whereArgs: [username],
    );
  }

  // ===================== Account Tree Operations =====================

  /// Insert an account tree node
  Future<void> insertAccountTreeNode(AccountTree node) async {
    final db = await getDatabase(node.username);
    await db.insert(
      accountTreeTable,
      node.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Insert multiple account tree nodes
  Future<void> insertAccountTreeNodes(List<AccountTree> nodes) async {
    if (nodes.isEmpty) return;
    final username = nodes.first.username;
    final db = await getDatabase(username);
    await db.transaction((txn) async {
      for (final node in nodes) {
        await txn.insert(
          accountTreeTable,
          node.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Get account tree for a user
  Future<List<AccountTree>> getAccountTreeForUser(String username) async {
    final db = await getDatabase(username);
    final result = await db.query(
      accountTreeTable,
      where: 'username = ?',
      whereArgs: [username],
      orderBy: 'sequence_order ASC, id ASC',
    );
    return result.map((map) => AccountTree.fromMap(map)).toList();
  }

  /// Get root folders for a user
  Future<List<AccountTree>> getRootFoldersForUser(String username) async {
    final db = await getDatabase(username);
    final result = await db.query(
      accountTreeTable,
      where: 'username = ? AND parent_id IS NULL',
      whereArgs: [username],
      orderBy: 'name ASC',
    );
    return result.map((map) => AccountTree.fromMap(map)).toList();
  }

  /// Get children of a folder
  Future<List<AccountTree>> getChildrenOf(
      String username, String? parentId) async {
    final db = await getDatabase(username);
    final result = await db.query(
      accountTreeTable,
      where: 'username = ? AND parent_id = ?',
      whereArgs: [username, parentId],
      orderBy: 'is_folder DESC, name ASC',
    );
    return result.map((map) => AccountTree.fromMap(map)).toList();
  }

  /// Delete all account tree nodes for a user
  Future<void> deleteAccountTreeForUser(String username) async {
    final db = await getDatabase(username);
    await db.delete(
      accountTreeTable,
      where: 'username = ?',
      whereArgs: [username],
    );
  }

  // ===================== Cached Account Operations =====================

  /// Delete all cached accounts for a user (to avoid duplicates before re-inserting)
  Future<void> deleteCachedAccountsForUser(String username) async {
    try {
      final db = await getDatabase(username);
      await db.delete(
        cachedAccountsTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      print('[CACHE] Deleted cached accounts for user: $username');
    } catch (e) {
      print('Error deleting cached accounts for $username: $e');
    }
  }

  /// Insert or update multiple cached accounts
  Future<void> insertCachedAccounts(
    List<CachedAccount> cachedAccounts,
  ) async {
    try {
      if (cachedAccounts.isEmpty) return;
      final username = cachedAccounts.first.username;
      final db = await getDatabase(username);
      await db.transaction((txn) async {
        for (final account in cachedAccounts) {
          await txn.insert(
            cachedAccountsTable,
            account.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e) {
      print('Error inserting cached accounts: $e');
    }
  }

  /// Get all cached accounts for a user
  Future<List<CachedAccount>> getCachedAccountsForUser(String username) async {
    try {
      final db = await getDatabase(username);
      final result = await db.query(
        cachedAccountsTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      return result.map((map) => CachedAccount.fromMap(map)).toList();
    } catch (e) {
      print('Error loading cached accounts for $username: $e');
      return [];
    }
  }

  /// Get a single cached account by ID
  Future<CachedAccount?> getCachedAccountById(
    String username,
    String accountId,
  ) async {
    try {
      final db = await getDatabase(username);
      final result = await db.query(
        cachedAccountsTable,
        where: 'username = ? AND id = ?',
        whereArgs: [username, accountId],
      );

      if (result.isEmpty) {
        return null;
      }
      return CachedAccount.fromMap(result.first);
    } catch (e) {
      print('Error loading cached account $accountId for $username: $e');
      return null;
    }
  }

  // ===================== Cached Password Operations =====================

  /// Insert or update a cached password
  Future<void> insertCachedPassword(CachedPassword cachedPassword) async {
    try {
      final startTime = DateTime.now();
      print('[DB_INSERT] 🟢 BEGIN: accountId=${cachedPassword.accountId}, username=${cachedPassword.username}');
      
      final db = await getDatabase(cachedPassword.username);
      print('[DB_INSERT] ✓ Connection acquired (${DateTime.now().difference(startTime).inMilliseconds}ms)');
      
      // CRITICAL: Verify user exists in users table before inserting cached password
      final userCheck = await db.query(
        usersTable,
        where: 'username = ?',
        whereArgs: [cachedPassword.username],
      );
      if (userCheck.isEmpty) {
        print('[DB_INSERT] ⚠️ WARNING: User ${cachedPassword.username} not found in users table! Creating stub entry...');
        // Create a stub user entry to satisfy foreign key constraint
        try {
          await db.insert(
            usersTable,
            {
              'username': cachedPassword.username,
              'password_hash': '',
              'is_logged_in': 0,
              'last_login': DateTime.now().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          print('[DB_INSERT] ✅ Created stub user entry for ${cachedPassword.username}');
        } catch (e) {
          print('[DB_INSERT] ⚠️ Could not create stub user: $e');
        }
      }
      
      // Create a map WITHOUT the id field so SQLite auto-generates it
      final insertMap = {
        'username': cachedPassword.username,
        'account_id': cachedPassword.accountId,
        'account_name': cachedPassword.accountName,
        'encrypted_password': cachedPassword.encryptedPassword,
        'cached_at': cachedPassword.cachedAt.toIso8601String(),
        'expires_at': cachedPassword.expiresAt?.toIso8601String(),
        'account_expiration_date': cachedPassword.accountExpirationDate?.toIso8601String(),
        'account_created_date': cachedPassword.accountCreatedDate?.toIso8601String(),
      };
      
      print('[DB_INSERT] 📋 Insert map: username=${insertMap['username']}, account_id=${insertMap['account_id']}, accountExpirationDate=${insertMap['account_expiration_date']}, accountCreatedDate=${insertMap['account_created_date']}, encrypted_password.length=${(insertMap['encrypted_password'] as String).length}');
      
      // Use explicit transaction for better control
      print('[DB_INSERT] 📝 Starting transaction...');
      await db.transaction((txn) async {
        final insertTime = DateTime.now();
        print('[DB_INSERT] 📝 Executing INSERT for ${cachedPassword.accountId}...');
        
        final insertResult = await txn.insert(
          cachedPasswordsTable,
          insertMap,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        
        print('[DB_INSERT] ✓ INSERT returned rowId=$insertResult (${DateTime.now().difference(insertTime).inMilliseconds}ms)');
        print('[DB_INSERT] 📝 Transaction will be committed automatically on return');
        
        // Verify within the SAME transaction before it commits
        final txnVerifyResult = await txn.query(
          cachedPasswordsTable,
          where: 'username = ? AND account_id = ?',
          whereArgs: [cachedPassword.username, cachedPassword.accountId],
        );
        print('[DB_INSERT] ✓ TRANSACTION-SCOPED VERIFY: found ${txnVerifyResult.length} row(s) inside transaction');
        if (txnVerifyResult.isNotEmpty) {
          print('[DB_INSERT] ✓ Inside transaction: cached_at=${txnVerifyResult.first['cached_at']}, expires_at=${txnVerifyResult.first['expires_at']}');
        }
      });
      print('[DB_INSERT] ✓ Transaction completed and committed');
      
      // CRITICAL: Verify the insert persisted AFTER transaction closed
      final verifyTime = DateTime.now();
      print('[DB_INSERT] 🔍 Post-transaction verification (outside txn)...');
      final verifyResult = await db.query(
        cachedPasswordsTable,
        where: 'username = ? AND account_id = ?',
        whereArgs: [cachedPassword.username, cachedPassword.accountId],
      );
      
      if (verifyResult.isEmpty) {
        // Query all rows to debug
        final allRows = await db.query(cachedPasswordsTable);
        final thisUserRows = await db.query(
          cachedPasswordsTable,
          where: 'username = ?',
          whereArgs: [cachedPassword.username],
        );
        print('[DB_INSERT] 🔍 DEBUG: Total rows in table=${allRows.length}, rows for ${cachedPassword.username}=${thisUserRows.length}');
        print('[DB_INSERT] 🔍 Rows for this user: ${thisUserRows.map((r) => '${r['account_id']}').toList()}');
        print('[DB_INSERT] 🔍 All account_ids in database: ${allRows.map((r) => '${r['account_id']}').toList()}');
        throw Exception('INSERT transaction completed but verification query returned EMPTY! Data not persisted to disk!');
      }
      
      print('[DB_INSERT] ✅ VERIFIED: accountId=${cachedPassword.accountId}, verified=${verifyResult.length} row(s), cached_at=${verifyResult.first['cached_at']}, verifyTime=${DateTime.now().difference(verifyTime).inMilliseconds}ms, totalTime=${DateTime.now().difference(startTime).inMilliseconds}ms');
    } catch (e) {
      print('[DB_INSERT] ❌ ERROR: accountId=${cachedPassword.accountId}: $e');
      print('[DB_INSERT] Stack trace: ${StackTrace.current}');
      rethrow;
    }
  }

  /// Insert or update multiple cached passwords
  Future<void> insertCachedPasswords(
      List<CachedPassword> cachedPasswords) async {
    if (cachedPasswords.isEmpty) return;
    final username = cachedPasswords.first.username;
    final db = await getDatabase(username);
    await db.transaction((txn) async {
      for (final cachedPassword in cachedPasswords) {
        await txn.insert(
          cachedPasswordsTable,
          cachedPassword.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Get cached password for an account
  Future<CachedPassword?> getCachedPassword(
      String username, String accountId) async {
    try {
      final startTime = DateTime.now();
      print('[DB_RETRIEVE] 🔍 START: username=$username, accountId=$accountId');
      
      final db = await getDatabase(username);
      
      // First, check all passwords in table for debugging
      final allResults = await db.query(cachedPasswordsTable);
      print('[DB_RETRIEVE] 📊 Total passwords in table: ${allResults.length}');
      if (allResults.isNotEmpty) {
        print('[DB_RETRIEVE] 📝 Accounts in DB: ${allResults.map((r) => r['account_id']).toList()}');
      }
      
      final result = await db.query(
        cachedPasswordsTable,
        where: 'username = ? AND account_id = ?',
        whereArgs: [username, accountId],
      );

      if (result.isEmpty) {
        print('[DB_RETRIEVE] ❌ Query returned EMPTY for $accountId (${DateTime.now().difference(startTime).inMilliseconds}ms)');
        return null;
      }
      
      print('[DB_RETRIEVE] ✅ Found password for $accountId (${DateTime.now().difference(startTime).inMilliseconds}ms)');
      return CachedPassword.fromMap(result.first);
    } catch (e) {
      print('[DB_RETRIEVE] 💥 ERROR: $e');
      rethrow;
    }
  }

  /// Get all cached passwords for a user
  Future<List<CachedPassword>> getCachedPasswordsForUser(
      String username) async {
    final db = await getDatabase(username);
    final result = await db.query(
      cachedPasswordsTable,
      where: 'username = ?',
      whereArgs: [username],
      orderBy: 'account_name ASC',
    );
    return result.map((map) => CachedPassword.fromMap(map)).toList();
  }

  /// Delete cached password for an account
  Future<void> deleteCachedPassword(String username, String accountId) async {
    final db = await getDatabase(username);
    await db.delete(
      cachedPasswordsTable,
      where: 'username = ? AND account_id = ?',
      whereArgs: [username, accountId],
    );
  }

  /// Delete all cached passwords for a user
  Future<void> deleteCachedPasswordsForUser(String username) async {
    try {
      final db = await getDatabase(username);
      print('[DB_DELETE] 🗑️  Deleting all cached passwords for user=$username...');
      
      // First, count existing rows
      final beforeCount = await db.query(
        cachedPasswordsTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      print('[DB_DELETE] 📊 Before delete: ${beforeCount.length} rows for $username (accounts: ${beforeCount.map((r) => r['account_id']).toList()})');
      
      final result = await db.delete(
        cachedPasswordsTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      
      print('[DB_DELETE] ✓ Delete completed: removed $result rows');
      
      // Verify deletion
      final afterCount = await db.query(
        cachedPasswordsTable,
        where: 'username = ?',
        whereArgs: [username],
      );
      print('[DB_DELETE] 📊 After delete: ${afterCount.length} rows for $username');
      if (afterCount.isNotEmpty) {
        print('[DB_DELETE] ⚠️  WARNING: Delete may have failed! Still have rows: ${afterCount.map((r) => r['account_id']).toList()}');
      }
    } catch (e) {
      print('[DB_DELETE] ❌ ERROR: $e');
      rethrow;
    }
  }

  /// Clear expired cached passwords
  Future<void> clearExpiredCachedPasswords(String username) async {
    final db = await getDatabase(username);
    await db.delete(
      cachedPasswordsTable,
      where: 'expires_at IS NOT NULL AND expires_at < ?',
      whereArgs: [DateTime.now().toIso8601String()],
    );
  }

  /// Comprehensive diagnostic dump - shows all database state
  Future<void> diagnosticDump(String username) async {
    try {
      final db = await getDatabase(username);
      
      print('\n╔════════════════════════════════════════════════════════════════╗');
      print('║ DATABASE DIAGNOSTIC DUMP FOR USER: $username');
      print('╚════════════════════════════════════════════════════════════════╝');
      
      // Get all passwords for this user
      final allPasswords = await db.query(
        cachedPasswordsTable,
        where: 'username = ?',
        whereArgs: [username],
        orderBy: 'account_id ASC',
      );
      
      print('\n📊 CACHED PASSWORDS TABLE - Total rows for $username: ${allPasswords.length}');
      
      if (allPasswords.isEmpty) {
        print('   ⚠️  TABLE IS EMPTY - NO CACHED PASSWORDS FOUND!');
      } else {
        print('   ┌─ Account IDs in database: ${allPasswords.map((p) => p['account_id']).toList()}');
        print('   │');
        
        for (final pwd in allPasswords) {
          final accountId = pwd['account_id']?.toString() ?? 'NULL';
          final accountName = pwd['account_name']?.toString() ?? 'NULL';
          final passwordPreview = pwd['encrypted_password'] != null 
            ? (pwd['encrypted_password'].toString().length > 20 
              ? '${pwd['encrypted_password'].toString().substring(0, 20)}...' 
              : pwd['encrypted_password'].toString())
            : 'NULL';
          final cachedAt = pwd['cached_at']?.toString() ?? 'NULL';
          final expiresAt = pwd['expires_at']?.toString() ?? 'NULL';
          
          print('   │');
          print('   ├─ 🔐 Account ID: $accountId');
          print('   │  Name: $accountName');
          print('   │  Password: $passwordPreview');
          print('   │  Cached: $cachedAt');
          print('   │  Expires: $expiresAt');
        }
        print('   │');
        print('   └─ ✅ Total: ${allPasswords.length} passwords cached');
      }
      
      // Get total count across ALL users
      final totalCount = await db.query(cachedPasswordsTable);
      print('\n📈 TOTAL PASSWORDS IN TABLE (ALL USERS): ${totalCount.length}');
      
      if (totalCount.isNotEmpty) {
        final uniqueUsers = <String>{};
        final uniqueAccounts = <String>{};
        
        for (final row in totalCount) {
          uniqueUsers.add(row['username']?.toString() ?? 'NULL');
          uniqueAccounts.add(row['account_id']?.toString() ?? 'NULL');
        }
        
        print('   Users in DB: ${uniqueUsers.toList()}');
        print('   Unique account IDs: ${uniqueAccounts.toList()}');
      }
      
      print('\n╔════════════════════════════════════════════════════════════════╗');
      print('║ END DIAGNOSTIC DUMP');
      print('╚════════════════════════════════════════════════════════════════╝\n');
      
    } catch (e) {
      print('[DIAGNOSTIC] ERROR: $e');
      print('[DIAGNOSTIC] Stack: ${StackTrace.current}');
    }
  }

  /// Close all databases
  Future<void> closeAll() async {
    // Close all open database connections
    for (final username in _databases.keys.toList()) {
      try {
        await _databases[username]!.close();
        _databases.remove(username);
        print('[DATABASE] 🔒 Closed database for user=$username');
      } catch (e) {
        print('[DATABASE] ⚠️  Error closing database for $username: $e');
      }
    }
  }
}
