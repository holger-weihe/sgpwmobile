import 'package:flutter/material.dart';
import '../models/user.dart';
import '../services/database_service.dart';
import '../services/certificate_service.dart';
import '../services/configuration_manager.dart';
import '../services/avatar_service.dart';

class DeleteUserScreen extends StatefulWidget {
  final User currentUser;
  final VoidCallback onUserDeleted;

  const DeleteUserScreen({
    super.key,
    required this.currentUser,
    required this.onUserDeleted,
  });

  @override
  State<DeleteUserScreen> createState() => _DeleteUserScreenState();
}

class _DeleteUserScreenState extends State<DeleteUserScreen> {
  bool _showConfirmation = false;
  bool _isDeleting = false;
  String? _errorMessage;

  Future<void> _performDelete() async {
    setState(() => _isDeleting = true);

    try {
      // Delete from database
      final databaseService = DatabaseService();
      await databaseService.deleteUser(widget.currentUser.username);

      // Delete certificates
      final certificateService = CertificateService();
      await certificateService.deleteCertificates(username: widget.currentUser.username);

      // Delete configuration
      final configManager = ConfigurationManager();
      await configManager.deleteConfig(username: widget.currentUser.username);

      // Delete avatar
      final avatarService = AvatarService();
      await avatarService.deleteAvatar(widget.currentUser.username);

      if (mounted) {
        widget.onUserDeleted();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error deleting user: $e';
        _isDeleting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showConfirmation) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Confirm Deletion'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              setState(() {
                _showConfirmation = false;
                _errorMessage = null;
              });
            },
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 64,
                color: Colors.red[300],
              ),
              const SizedBox(height: 24),
              const Text(
                'Delete User?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  border: Border.all(color: Colors.red[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'This will delete the User and all data stored',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.red,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    border: Border.all(color: Colors.orange[300]!),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(color: Colors.orange[900], fontSize: 12),
                  ),
                ),
              if (_errorMessage != null) const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _isDeleting ? null : _performDelete,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: _isDeleting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    : const Text('Delete User'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isDeleting
                    ? null
                    : () {
                        setState(() {
                          _showConfirmation = false;
                          _errorMessage = null;
                        });
                      },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Delete User'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.person_remove_outlined,
              size: 64,
              color: Colors.red[300],
            ),
            const SizedBox(height: 24),
            const Text(
              'Delete User Account',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Current User',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.currentUser.username,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red[50],
                border: Border.all(color: Colors.red[200]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Warning: This action cannot be undone. All associated data including certificates, configurations, and cached passwords will be permanently deleted.',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.red,
                ),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _showConfirmation = true;
                });
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete User'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
