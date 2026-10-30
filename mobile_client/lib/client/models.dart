enum UserRole {
  admin('Admin', 'Quản trị'),
  producer('Producer', 'Nhà sản xuất'),
  trader('Trader', 'Thương lái'),
  consumer('Consumer', 'Người tiêu dùng');

  const UserRole(this.wire, this.label);
  final String wire;
  final String label;
  static UserRole parse(String value) =>
      values.firstWhere((r) => r.wire == value);
}

enum ApprovalStatus {
  pending('Pending', 'Chờ duyệt'),
  needsInformation('NeedsInformation', 'Cần bổ sung'),
  approved('Approved', 'Đã duyệt'),
  rejected('Rejected', 'Từ chối');

  const ApprovalStatus(this.wire, this.label);
  final String wire;
  final String label;
  static ApprovalStatus parse(String value) =>
      values.firstWhere((s) => s.wire == value);
}

class Account {
  const Account({
    required this.id,
    required this.displayName,
    required this.email,
    required this.role,
    required this.approvalStatus,
    required this.region,
    required this.isActive,
    this.reviewReason,
    this.twoFactorEnabled = false,
    this.emailConfirmed = false,
    this.countryCode,
    this.provinceCode,
  });
  factory Account.fromJson(Map<String, dynamic> data) => Account(
    id: data['id'] as String,
    displayName: data['displayName'] as String,
    email: data['email'] as String,
    role: UserRole.parse(data['role'] as String),
    approvalStatus: ApprovalStatus.parse(data['approvalStatus'] as String),
    region: data['region'] as String? ?? '',
    isActive: data['isActive'] as bool,
    reviewReason: data['reviewReason'] as String?,
    twoFactorEnabled: data['twoFactorEnabled'] as bool? ?? false,
    emailConfirmed: data['emailConfirmed'] == true,
    countryCode: data['countryCode'] as String?,
    provinceCode: data['provinceCode'] as String?,
  );
  final String id, displayName, email, region;
  final UserRole role;
  final ApprovalStatus approvalStatus;
  final bool isActive, twoFactorEnabled, emailConfirmed;
  final String? countryCode, provinceCode;
  final String? reviewReason;
  bool get isApproved => isActive && approvalStatus == ApprovalStatus.approved;
  bool get isAdmin => role == UserRole.admin;
  bool get canSell =>
      isApproved && (role == UserRole.producer || role == UserRole.trader);
  bool get canResubmit =>
      approvalStatus == ApprovalStatus.needsInformation ||
      approvalStatus == ApprovalStatus.rejected;
}

class TokenPair {
  const TokenPair(this.accessToken, this.refreshToken, this.expiresAt);
  factory TokenPair.fromResponse(Map<String, dynamic> data) => TokenPair(
    data['accessToken'] as String,
    data['refreshToken'] as String,
    DateTime.now().toUtc().add(
      Duration(seconds: (data['expiresIn'] as num).toInt()),
    ),
  );
  factory TokenPair.fromJson(Map<String, dynamic> data) => TokenPair(
    data['accessToken'] as String,
    data['refreshToken'] as String,
    DateTime.parse(data['expiresAt'] as String).toUtc(),
  );
  final String accessToken, refreshToken;
  final DateTime expiresAt;
  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toIso8601String(),
  };
}

class ApiException implements Exception {
  const ApiException(this.message, {this.status = 0});
  final String message;
  final int status;
  @override
  String toString() => message;
}
