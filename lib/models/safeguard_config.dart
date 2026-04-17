class SafeguardConfig {
  final String serverAddress;
  final String certificateKey;
  final String privateKeyKey;
  final String? authenticationProviderName;
  final String? authenticationRstsProviderId;
  final String? authenticationUsername;
  final String? authenticationPassword;

  SafeguardConfig({
    required this.serverAddress,
    required this.certificateKey,
    required this.privateKeyKey,
    this.authenticationProviderName,
    this.authenticationRstsProviderId,
    this.authenticationUsername,
    this.authenticationPassword,
  });

  factory SafeguardConfig.fromJson(Map<String, dynamic> json) {
    return SafeguardConfig(
      serverAddress: json['serverAddress'] as String,
      certificateKey: json['certificateKey'] as String,
      privateKeyKey: json['privateKeyKey'] as String,
      authenticationProviderName: json['authenticationProviderName'] as String?,
      authenticationRstsProviderId: json['authenticationRstsProviderId'] as String?,
      authenticationUsername: json['authenticationUsername'] as String?,
      authenticationPassword: json['authenticationPassword'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serverAddress': serverAddress,
      'certificateKey': certificateKey,
      'privateKeyKey': privateKeyKey,
      'authenticationProviderName': authenticationProviderName,
      'authenticationRstsProviderId': authenticationRstsProviderId,
      'authenticationUsername': authenticationUsername,
      'authenticationPassword': authenticationPassword,
    };
  }
}
