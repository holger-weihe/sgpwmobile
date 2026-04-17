enum HttpMethod {
  get('GET'),
  post('POST'),
  put('PUT'),
  delete('DELETE');

  final String value;
  const HttpMethod(this.value);

  @override
  String toString() => value;
}

class ApiRequest {
  final HttpMethod method;
  final String endpoint;
  final String? body;
  final DateTime createdAt;

  ApiRequest({
    required this.method,
    required this.endpoint,
    this.body,
  }) : createdAt = DateTime.now();

  String get displayName {
    if (body != null && body!.isNotEmpty) {
      return '$method $endpoint (with body)';
    }
    return '$method $endpoint';
  }

  bool get isValid => endpoint.isNotEmpty && endpoint.startsWith('/');

  Map<String, dynamic> toJson() {
    return {
      'method': method.value,
      'endpoint': endpoint,
      'body': body,
    };
  }

  factory ApiRequest.fromJson(Map<String, dynamic> json) {
    final methodStr = json['method'] as String;
    final method = HttpMethod.values.firstWhere(
      (m) => m.value == methodStr,
      orElse: () => HttpMethod.get,
    );

    return ApiRequest(
      method: method,
      endpoint: json['endpoint'] as String,
      body: json['body'] as String?,
    );
  }
}

class ApiResponse {
  final int statusCode;
  final String body;
  final bool isSuccess;
  final DateTime timestamp;
  final String? errorMessage;

  ApiResponse({
    required this.statusCode,
    required this.body,
    required this.isSuccess,
    this.errorMessage,
  }) : timestamp = DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'statusCode': statusCode,
      'body': body,
      'isSuccess': isSuccess,
      'timestamp': timestamp.toIso8601String(),
      'errorMessage': errorMessage,
    };
  }
}
