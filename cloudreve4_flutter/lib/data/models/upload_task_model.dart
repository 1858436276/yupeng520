import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../../services/task_database.dart';

/// 上传状态
enum UploadStatus {
  waiting,   // 等待中
  uploading, // 上传中
  completed, // 已完成
  paused,    // 已暂停
  failed,    // 失败
  cancelled, // 已取消
}

/// 上传会话模型（从 API 返回的上传会话信息）
class UploadSessionModel {
  final String sessionId;
  final String? uploadId;
  final int chunkSize;
  final int expires;
  final List<String>? uploadUrls;
  final String? credential;
  final String? completeUrl;
  final StoragePolicyModel storagePolicy;
  final String? mimeType;
  final String? uploadPolicy;
  final String? callbackSecret;

  /// 服务端下发的客户端加密参数。
  ///
  /// 当存储策略开启文件加密且未使用中转上传时，Cloudreve 返回
  /// `encrypt_metadata`，要求客户端使用 AES-256-CTR 在上传前对分片加密。
  /// 中转上传（relay）时该字段为 null，由服务端负责流式加密。
  final EncryptMetadataModel? encryptMetadata;

  UploadSessionModel({
    required this.sessionId,
    this.uploadId,
    required this.chunkSize,
    required this.expires,
    this.uploadUrls,
    this.credential,
    this.completeUrl,
    required this.storagePolicy,
    this.mimeType,
    this.uploadPolicy,
    this.callbackSecret,
    this.encryptMetadata,
  });

  factory UploadSessionModel.fromJson(Map<String, dynamic> json) {
    final storagePolicyJson = json['storage_policy'] as Map<String, dynamic>? ??
        json['storagePolicy'] as Map<String, dynamic>? ??
        <String, dynamic>{
          'id': '',
          'name': '',
          'type': '',
          'max_size': 0,
        };

    return UploadSessionModel(
      sessionId: json['session_id']?.toString() ??
          json['sessionId']?.toString() ??
          '',
      uploadId: json['upload_id']?.toString() ?? json['uploadId']?.toString(),
      chunkSize: (json['chunk_size'] as num?)?.toInt() ??
          (json['chunkSize'] as num?)?.toInt() ??
          0,
      expires: (json['expires'] as num?)?.toInt() ?? 0,
      uploadUrls: json['upload_urls'] != null
          ? (json['upload_urls'] as List).map((e) => e.toString()).toList()
          : json['uploadUrls'] != null
              ? (json['uploadUrls'] as List).map((e) => e.toString()).toList()
              : null,
      credential: json['credential']?.toString(),
      completeUrl: json['completeURL']?.toString() ??
          json['complete_url']?.toString() ??
          json['completeUrl']?.toString(),
      storagePolicy: StoragePolicyModel.fromJson(storagePolicyJson),
      mimeType: json['mime_type']?.toString() ?? json['mimeType']?.toString(),
      uploadPolicy:
          json['upload_policy']?.toString() ?? json['uploadPolicy']?.toString(),
      callbackSecret: json['callback_secret']?.toString() ??
          json['callbackSecret']?.toString(),
      encryptMetadata: EncryptMetadataModel.fromJson(
        json['encrypt_metadata'] ?? json['encryptMetadata'],
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'session_id': sessionId,
      'upload_id': uploadId,
      'chunk_size': chunkSize,
      'expires': expires,
      'upload_urls': uploadUrls,
      'credential': credential,
      'completeURL': completeUrl,
      'storage_policy': storagePolicy.toJson(),
      'mime_type': mimeType,
      'upload_policy': uploadPolicy,
      'callback_secret': callbackSecret,
      'encrypt_metadata': encryptMetadata?.toJson(),
    };
  }

  /// 是否支持分片上传
  bool get isMultipartEnabled => chunkSize > 0;

  /// 是否使用中继上传（上传到 Cloudreve 服务器）
  bool get isRelayUpload => storagePolicy.relay == true || storagePolicy.type == 'local';

  /// 是否需要客户端在上传前进行 AES-256-CTR 加密。
  ///
  /// 判定依据仅看服务端是否返回了 `encrypt_metadata`：
  /// - 中转上传（relay）时服务端恒返回 null（此时 `ClientSideEncrypted=false`，
  ///   由服务端流式加密），因此不需要再叠加 `isRelayUpload` 判断；
  /// - 从机（stateless）模式下即使策略 relay=true，服务端也会走 unrelayed
  ///   分支返回 encrypt_metadata 并要求客户端加密，叠加 `isRelayUpload` 会误伤，
  ///   导致明文上传后服务端按密文解密失败。
  bool get requiresClientEncryption => encryptMetadata != null;
}

/// 客户端加密参数（对应服务端响应中的 `encrypt_metadata`）。
class EncryptMetadataModel {
  /// 加密算法，例如 `aes-256-ctr`。
  final String? algorithm;

  /// Base64 编码的 32 字节 AES-256 密钥。
  final String? keyPlainText;

  /// Base64 编码的 16 字节初始化向量。
  final String? iv;

  EncryptMetadataModel({
    this.algorithm,
    this.keyPlainText,
    this.iv,
  });

  static EncryptMetadataModel? fromJson(dynamic json) {
    // 服务端未返回 encrypt_metadata（中转上传或策略未开启加密）时必须返回 null，
    // 否则空对象会让 requiresClientEncryption 误判为需要客户端加密。
    if (json == null) return null;
    final map = json is Map<String, dynamic>
        ? json
        : json is Map
            ? Map<String, dynamic>.from(json)
            : <String, dynamic>{};

    return EncryptMetadataModel(
      algorithm: map['algorithm']?.toString() ??
          map['cipher']?.toString(),
      keyPlainText: map['key_plain_text']?.toString() ??
          map['keyPlainText']?.toString(),
      iv: map['iv']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'algorithm': algorithm,
      'key_plain_text': keyPlainText,
      'iv': iv,
    };
  }
}

/// 存储策略模型
class StoragePolicyModel {
  final String id;
  final String name;
  final String type;
  final int maxSize;
  final bool? relay;

  /// 允许的最大并发分片上传数。
  final int? chunkConcurrency;

  /// 是否支持流式加密（分片边界无需与 AES 块边界对齐）。
  final bool? streamingEncryption;

  StoragePolicyModel({
    required this.id,
    required this.name,
    required this.type,
    required this.maxSize,
    this.relay,
    this.chunkConcurrency,
    this.streamingEncryption,
  });

  factory StoragePolicyModel.fromJson(Map<String, dynamic> json) {
    return StoragePolicyModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ??
          json['policy_type']?.toString() ??
          json['policyType']?.toString() ??
          '',
      maxSize: (json['max_size'] as num?)?.toInt() ??
          (json['maxSize'] as num?)?.toInt() ??
          0,
      relay: json['relay'] as bool?,
      chunkConcurrency: (json['chunk_concurrency'] as num?)?.toInt() ??
          (json['chunkConcurrency'] as num?)?.toInt(),
      streamingEncryption: json['streaming_encryption'] as bool? ??
          json['streamingEncryption'] as bool?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'max_size': maxSize,
      'relay': relay,
      'chunk_concurrency': chunkConcurrency,
      'streaming_encryption': streamingEncryption,
    };
  }
}

/// 上传任务模型
class UploadTaskModel {
  static const Object _unset = Object();

  final String id;
  final File file;
  final String fileName;
  final int fileSize;
  final String targetPath; // 目标路径，例如 cloudreve://my/subfolder

  /// Android SAF / ContentResolver 原始文件 URI。
  ///
  /// 如果非空且以 content:// 开头，上传时优先通过 Android 原生 ContentResolver
  /// 按 offset/length 分片读取，不再依赖 file_picker 复制出来的缓存文件。
  final String? sourceUri;

  /// 是否覆盖上传。
  ///
  /// 对应 Cloudreve 创建上传会话时的 `entity_type: "version"`，会把已有同名文件
  /// 当作新版本写入而不是直接报 ObjectExisted。
  final bool overwrite;

  /// 是否在 UI / 通知 / 本地持久化中隐藏。
  ///
  /// 编辑器的"保存"会调用上传服务，但保存场景不希望污染任务管理页：
  /// 同一文件保存 N 次会出现 N 条任务，且重启后仍存在。
  /// 设为 true 后：
  /// - allTasks / activeTasks 不返回该任务
  /// - _saveTasks 不持久化
  /// - 前台通知不计入
  /// - 终态（completed / failed / cancelled）后自动从 _tasks 移除
  final bool hidden;

  final DateTime createdAt;
  DateTime? completedAt;
  final UploadStatus status;
  final int uploadedBytes;
  final double progress;
  final int uploadedChunks; // 已上传的分片数量
  final int totalChunks; // 总分片数量
  final String? errorMessage;
  final UploadSessionModel? session; // 上传会话信息
  final int speed; // 上传速度，字节/秒

  UploadTaskModel({
    required this.id,
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.targetPath,
    this.sourceUri,
    this.overwrite = false,
    this.hidden = false,
    DateTime? createdAt,
    this.completedAt,
    UploadStatus? status,
    this.uploadedBytes = 0,
    this.progress = 0,
    this.uploadedChunks = 0,
    this.totalChunks = 1,
    this.errorMessage,
    this.session,
    this.speed = 0,
  })  : createdAt = createdAt ?? DateTime.now(),
      status = status ?? UploadStatus.waiting;

  bool get usesContentUri =>
      sourceUri != null && sourceUri!.toLowerCase().startsWith('content://');

  /// 计算总分片数
  int calculateTotalChunks(int chunkSize) {
    if (chunkSize <= 0) return 1;
    return (fileSize / chunkSize).ceil();
  }

  /// 获取状态文本
  String get statusText {
    switch (status) {
      case UploadStatus.waiting:
        return '等待中';
      case UploadStatus.uploading:
        return '上传中...';
      case UploadStatus.completed:
        return '上传完成';
      case UploadStatus.paused:
        return '已暂停';
      case UploadStatus.failed:
        return '上传失败';
      case UploadStatus.cancelled:
        return '已取消';
    }
  }

  /// 获取进度文本
  String get progressText {
    if (status == UploadStatus.completed) {
      return '100%';
    }
    return '${(progress * 100).toStringAsFixed(1)}%';
  }

  /// 获取可读的文件大小
  String get readableFileSize {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  /// 获取可读的上传速度
  String get speedText {
    final value = speed < 0 ? 0 : speed;
    if (value < 1024) return '$value B/s';
    if (value < 1024 * 1024) {
      return '${(value / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  /// 克隆任务
  ///
  /// session/errorMessage 支持传 null 来主动清空。
  UploadTaskModel copyWith({
    UploadStatus? status,
    int? uploadedBytes,
    double? progress,
    int? uploadedChunks,
    int? totalChunks,
    Object? errorMessage = _unset,
    Object? session = _unset,
    DateTime? completedAt,
    int? speed,
    String? sourceUri,
  }) {
    return UploadTaskModel(
      id: id,
      file: file,
      fileName: fileName,
      fileSize: fileSize,
      targetPath: targetPath,
      sourceUri: sourceUri ?? this.sourceUri,
      overwrite: overwrite,
      hidden: hidden,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
      status: status ?? this.status,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      progress: progress ?? this.progress,
      uploadedChunks: uploadedChunks ?? this.uploadedChunks,
      totalChunks: totalChunks ?? this.totalChunks,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      session: identical(session, _unset)
          ? this.session
          : session as UploadSessionModel?,
      speed: speed ?? this.speed,
    );
  }

  /// 转换为 JSON（用于持久化）
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'file_path': file.path,
      'file_name': fileName,
      'file_size': fileSize,
      'target_path': targetPath,
      'source_uri': sourceUri,
      'overwrite': overwrite,
      'created_at': createdAt.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
      'status': status.index,
      'uploaded_bytes': uploadedBytes,
      'progress': progress,
      'uploaded_chunks': uploadedChunks,
      'total_chunks': totalChunks,
      'error_message': errorMessage,
      'speed': speed,
      'session': session?.toJson(),
    };
  }

  /// 从 JSON 创建（用于持久化恢复）
  factory UploadTaskModel.fromJson(Map<String, dynamic> json) {
    return UploadTaskModel(
      id: json['id'] as String,
      file: File(json['file_path']?.toString() ?? ''),
      fileName: json['file_name'] as String,
      fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
      targetPath: json['target_path'] as String,
      sourceUri: json['source_uri']?.toString(),
      overwrite: json['overwrite'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
      status: UploadStatus.values[(json['status'] as num?)?.toInt() ?? 0],
      uploadedBytes: (json['uploaded_bytes'] as num?)?.toInt() ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      uploadedChunks: (json['uploaded_chunks'] as num?)?.toInt() ?? 0,
      totalChunks: (json['total_chunks'] as num?)?.toInt() ?? 1,
      errorMessage: json['error_message'] as String?,
      session: json['session'] is Map
          ? UploadSessionModel.fromJson(
              Map<String, dynamic>.from(json['session'] as Map),
            )
          : null,
      speed: (json['speed'] as num?)?.toInt() ?? 0,
    );
  }

  /// 转换为 drift Companion（用于 upsert 到 upload_tasks 表）
  ///
  /// hidden 字段不持久化（与原 _saveTasks 过滤一致）。
  /// session 字段序列化为 JSON 字符串存储。
  UploadTasksCompanion toCompanion() {
    return UploadTasksCompanion(
      id: Value(id),
      filePath: Value(file.path),
      fileName: Value(fileName),
      fileSize: Value(fileSize),
      targetPath: Value(targetPath),
      sourceUri: Value(sourceUri),
      overwrite: Value(overwrite),
      createdAt: Value(createdAt.toIso8601String()),
      completedAt: Value(completedAt?.toIso8601String()),
      status: Value(status.index),
      uploadedBytes: Value(uploadedBytes),
      progress: Value(progress),
      uploadedChunks: Value(uploadedChunks),
      totalChunks: Value(totalChunks),
      errorMessage: Value(errorMessage),
      session: Value(session == null ? null : jsonEncode(session!.toJson())),
      speed: Value(speed),
      updatedAt: Value(DateTime.now().toIso8601String()),
    );
  }

  /// 从 drift Entry 创建（用于查询结果转换）
  factory UploadTaskModel.fromEntry(UploadTaskEntry entry) {
    return UploadTaskModel(
      id: entry.id,
      file: File(entry.filePath),
      fileName: entry.fileName,
      fileSize: entry.fileSize,
      targetPath: entry.targetPath,
      sourceUri: entry.sourceUri,
      overwrite: entry.overwrite,
      createdAt: DateTime.parse(entry.createdAt),
      completedAt: entry.completedAt == null
          ? null
          : DateTime.parse(entry.completedAt!),
      status: UploadStatus.values[entry.status],
      uploadedBytes: entry.uploadedBytes,
      progress: entry.progress,
      uploadedChunks: entry.uploadedChunks,
      totalChunks: entry.totalChunks,
      errorMessage: entry.errorMessage,
      session: entry.session == null || entry.session!.isEmpty
          ? null
          : UploadSessionModel.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(entry.session!) as Map,
              ),
            ),
      speed: entry.speed,
    );
  }
}
