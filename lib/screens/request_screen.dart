import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/api_request.dart';
import '../services/configuration_manager.dart';
import '../services/safeguard_service.dart';

class RequestScreen extends StatefulWidget {
  final ConfigurationManager configManager;
  final SafeguardService safeguardService;

  const RequestScreen({
    super.key,
    required this.configManager,
    required this.safeguardService,
  });

  @override
  State<RequestScreen> createState() => _RequestScreenState();
}

class _RequestScreenState extends State<RequestScreen> {
  final _endpointController = TextEditingController();
  final _bodyController = TextEditingController();
  HttpMethod _selectedMethod = HttpMethod.get;
  bool _isExecuting = false;
  String? _responseBody;
  int? _responseStatusCode;
  String? _errorMessage;
  bool _showFormattedJson = false;

  @override
  void initState() {
    super.initState();
    // Set a default friendly endpoint
    _endpointController.text = '/service/core/v4/Users';
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  String? _validateEndpoint(String value) {
    if (value.isEmpty) {
      return 'Endpoint is required';
    }
    if (!value.startsWith('/')) {
      return 'Endpoint must start with /';
    }
    return null;
  }

  Future<void> _executeRequest() async {
    // Check if authentication is available
    if (!widget.safeguardService.isAuthenticated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Authentication required. Please configure and authenticate in the Setup screen first.'),
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    final endpointError = _validateEndpoint(_endpointController.text);
    if (endpointError != null) {
      setState(() {
        _errorMessage = endpointError;
      });
      return;
    }

    setState(() {
      _isExecuting = true;
      _errorMessage = null;
      _responseBody = null;
      _responseStatusCode = null;
    });

    try {
      final request = ApiRequest(
        method: _selectedMethod,
        endpoint: _endpointController.text,
        body: _selectedMethod != HttpMethod.get && _selectedMethod != HttpMethod.delete
            ? (_bodyController.text.isEmpty ? null : _bodyController.text)
            : null,
      );

      final response = await widget.safeguardService.executeApiRequest(request);

      setState(() {
        _responseStatusCode = response.statusCode;
        if (response.isSuccess) {
          _responseBody = response.body;
          _errorMessage = null;
          _showFormattedJson = false;
        } else {
          _responseBody = response.body;
          _errorMessage = response.errorMessage ?? 'Request failed';
        }
        _isExecuting = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isExecuting = false;
      });
    }
  }

  String _formatJson(String jsonString) {
    try {
      final decoded = jsonDecode(jsonString);
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(decoded);
    } catch (e) {
      return jsonString;
    }
  }

  void _copyToClipboard(String text) {
    // For a production app, use the clipboard package
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Response copied to clipboard')),
    );
  }

  Color _getStatusCodeColor(int statusCode) {
    if (statusCode >= 200 && statusCode < 300) {
      return Colors.green;
    } else if (statusCode >= 400 && statusCode < 500) {
      return Colors.orange;
    } else if (statusCode >= 500) {
      return Colors.red;
    }
    return Colors.grey;
  }

  Color _getMethodColor(HttpMethod method) {
    switch (method) {
      case HttpMethod.get:
        return const Color(0xFF2196F3); // Blue
      case HttpMethod.post:
        return const Color(0xFF4CAF50); // Green
      case HttpMethod.put:
        return const Color(0xFFFF9800); // Orange
      case HttpMethod.delete:
        return const Color(0xFFF44336); // Red
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            // HTTP Method Selector
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'HTTP Method',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: HttpMethod.values.map((method) {
                          final isSelected = _selectedMethod == method;
                          final methodColor = _getMethodColor(method);
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: ElevatedButton(
                              onPressed: _isExecuting
                                  ? null
                                  : () {
                                      setState(() {
                                        _selectedMethod = method;
                                      });
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isSelected ? methodColor : Colors.grey.shade300,
                                foregroundColor: isSelected ? Colors.white : Colors.grey.shade700,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                elevation: isSelected ? 4 : 0,
                              ),
                              child: Text(
                                method.value.toUpperCase(),
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Endpoint Input
            TextField(
              controller: _endpointController,
              enabled: !_isExecuting,
              decoration: InputDecoration(
                labelText: 'API Endpoint',
                hintText: '/service/core/v4/Users',
                border: const OutlineInputBorder(),
                prefix: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getMethodColor(_selectedMethod),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _selectedMethod.value.toUpperCase(),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ),
                helperText: 'Must start with /',
              ),
            ),
            const SizedBox(height: 16),
            // Request Body (if applicable)
            if (_selectedMethod != HttpMethod.get &&
                _selectedMethod != HttpMethod.delete)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Request Body (JSON)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _bodyController,
                    enabled: !_isExecuting,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '{\n  "key": "value"\n}',
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            // Execute Button
            ElevatedButton.icon(
              onPressed: _isExecuting ? null : _executeRequest,
              icon: _isExecuting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.send),
              label: Text(_isExecuting ? 'Sending...' : 'Send Request'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            // Response Section
            if (_responseStatusCode != null || _errorMessage != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Response',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const Spacer(),
                              if (_responseStatusCode != null)
                                Container(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _getStatusCodeColor(_responseStatusCode!)
                                        .withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: _getStatusCodeColor(_responseStatusCode!),
                                    ),
                                  ),
                                  child: Text(
                                    _responseStatusCode.toString(),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color:
                                          _getStatusCodeColor(_responseStatusCode!),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_errorMessage != null)
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                border: Border.all(color: Colors.red),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error, color: Colors.red, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: const TextStyle(
                                        color: Colors.red,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (_responseBody != null && _responseBody!.isNotEmpty)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Body',
                                      style: TextStyle(fontWeight: FontWeight.w500),
                                    ),
                                    Row(
                                      children: [
                                        TextButton.icon(
                                          onPressed: () {
                                            setState(() {
                                              _showFormattedJson = !_showFormattedJson;
                                            });
                                          },
                                          icon: Icon(_showFormattedJson
                                              ? Icons.unfold_less
                                              : Icons.unfold_more),
                                          label: Text(_showFormattedJson
                                              ? 'Collapse'
                                              : 'Format'),
                                        ),
                                        IconButton(
                                          onPressed: () =>
                                              _copyToClipboard(_responseBody!),
                                          icon: const Icon(Icons.copy, size: 16),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    border: Border.all(color: Colors.grey.shade300),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  constraints: const BoxConstraints(
                                    maxHeight: 400,
                                  ),
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.vertical,
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Text(
                                        _showFormattedJson
                                            ? _formatJson(_responseBody!)
                                            : _responseBody!,
                                        style: const TextStyle(
                                          fontFamily: 'Courier',
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
