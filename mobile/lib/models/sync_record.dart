class SyncRecord {
  const SyncRecord({
    required this.id,
    required this.kind,
    required this.data,
    this.parentId,
    this.revision = 0,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  final String id, kind, createdAt, updatedAt;
  final String? parentId, deletedAt;
  final int revision;
  final Map<String, dynamic> data;
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'parentId': parentId,
    'revision': revision,
    'deletedAt': deletedAt,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'data': data,
  };
  factory SyncRecord.fromJson(Map<String, dynamic> value) => SyncRecord(
    id: value['id'] as String,
    kind: value['kind'] as String,
    parentId: value['parentId'] as String?,
    revision: value['revision'] as int,
    deletedAt: value['deletedAt'] as String?,
    createdAt: value['createdAt'] as String,
    updatedAt: value['updatedAt'] as String,
    data: Map<String, dynamic>.from(value['data'] as Map),
  );
}
