import 'dart:convert';
import 'dart:io';

import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:path_provider/path_provider.dart';

import 'meshy_proxy_client.dart';

const defaultMeshyModelHistoryLimit = 20;
const _modelCacheDirectoryName = 'meshy_models';
const _modelHistoryIndexFileName = 'history.json';

enum MeshyPlacementRuntime { android, iOS, other }

MeshyPlacementRuntime detectMeshyPlacementRuntime() {
  if (Platform.isAndroid) {
    return MeshyPlacementRuntime.android;
  }
  if (Platform.isIOS) {
    return MeshyPlacementRuntime.iOS;
  }
  return MeshyPlacementRuntime.other;
}

class MeshyModelHistoryException implements Exception {
  const MeshyModelHistoryException(this.message);

  final String message;

  @override
  String toString() => 'MeshyModelHistoryException: $message';
}

class MeshyModelRecord {
  const MeshyModelRecord({
    required this.id,
    required this.prompt,
    required this.localRelativePath,
    required this.originalGlbUrl,
    required this.createdAt,
    required this.updatedAt,
    required this.lastUsedAt,
    this.thumbnailUrl,
  });

  final String id;
  final String prompt;
  final String localRelativePath;
  final String originalGlbUrl;
  final String? thumbnailUrl;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastUsedAt;

  factory MeshyModelRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final prompt = json['prompt'] as String?;
    final localRelativePath = json['localRelativePath'] as String?;
    final originalGlbUrl = json['originalGlbUrl'] as String?;
    final createdAt = _readRequiredDateTime(json, 'createdAt');
    final updatedAt = _readRequiredDateTime(json, 'updatedAt');
    final lastUsedAt = _readRequiredDateTime(json, 'lastUsedAt');

    if (id == null ||
        prompt == null ||
        localRelativePath == null ||
        originalGlbUrl == null) {
      throw const MeshyModelHistoryException(
        'The model history index contained an invalid entry.',
      );
    }

    return MeshyModelRecord(
      id: id,
      prompt: prompt,
      localRelativePath: localRelativePath,
      originalGlbUrl: originalGlbUrl,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastUsedAt: lastUsedAt,
    );
  }

  MeshyModelRecord copyWith({
    String? id,
    String? prompt,
    String? localRelativePath,
    String? originalGlbUrl,
    String? thumbnailUrl,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
  }) {
    return MeshyModelRecord(
      id: id ?? this.id,
      prompt: prompt ?? this.prompt,
      localRelativePath: localRelativePath ?? this.localRelativePath,
      originalGlbUrl: originalGlbUrl ?? this.originalGlbUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'prompt': prompt,
      'localRelativePath': localRelativePath,
      'originalGlbUrl': originalGlbUrl,
      'thumbnailUrl': thumbnailUrl,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'lastUsedAt': lastUsedAt.toUtc().toIso8601String(),
    };
  }

  static DateTime _readRequiredDateTime(
    Map<String, dynamic> json,
    String field,
  ) {
    final value = json[field];
    if (value is! String) {
      throw const MeshyModelHistoryException(
        'The model history index contained an invalid timestamp.',
      );
    }

    final timestamp = DateTime.tryParse(value)?.toUtc();
    if (timestamp == null) {
      throw const MeshyModelHistoryException(
        'The model history index contained an invalid timestamp.',
      );
    }
    return timestamp;
  }
}

class MeshyPlacementSource {
  const MeshyPlacementSource({required this.nodeType, required this.nodeUri});

  final NodeType nodeType;
  final String nodeUri;

  factory MeshyPlacementSource.webGlb(String glbUrl) {
    return MeshyPlacementSource(nodeType: NodeType.webGLB, nodeUri: glbUrl);
  }

  factory MeshyPlacementSource.localGlb(String relativePath) {
    return MeshyPlacementSource(
      nodeType: NodeType.fileSystemAppFolderGLB,
      nodeUri: relativePath,
    );
  }
}

class MeshyActiveModel {
  const MeshyActiveModel._({
    required this.id,
    required this.prompt,
    required this.placementSource,
    required this.isPersisted,
    this.localRelativePath,
    this.thumbnailUrl,
    this.originalGlbUrl,
    this.retryPlacementSource,
  });

  final String id;
  final String prompt;
  final MeshyPlacementSource placementSource;
  final bool isPersisted;
  final String? localRelativePath;
  final String? thumbnailUrl;
  final String? originalGlbUrl;
  final MeshyPlacementSource? retryPlacementSource;

  NodeType get nodeType => placementSource.nodeType;

  String get nodeUri => placementSource.nodeUri;

  bool get hasRetryPlacementSource => retryPlacementSource != null;

  factory MeshyActiveModel.fromRecord(
    MeshyModelRecord record, {
    required MeshyPlacementRuntime runtime,
  }) {
    final localSource = MeshyPlacementSource.localGlb(record.localRelativePath);
    final remoteSource = record.originalGlbUrl.trim().isEmpty
        ? null
        : MeshyPlacementSource.webGlb(record.originalGlbUrl);
    final selection = _selectPlacementSources(
      runtime: runtime,
      localSource: localSource,
      remoteSource: remoteSource,
    );

    return MeshyActiveModel._(
      id: record.id,
      prompt: record.prompt,
      placementSource: selection.primary,
      isPersisted: true,
      localRelativePath: record.localRelativePath,
      thumbnailUrl: record.thumbnailUrl,
      originalGlbUrl: record.originalGlbUrl,
      retryPlacementSource: selection.retry,
    );
  }

  factory MeshyActiveModel.remoteSession({
    required String id,
    required String prompt,
    required String glbUrl,
    String? thumbnailUrl,
  }) {
    return MeshyActiveModel._(
      id: id,
      prompt: prompt,
      placementSource: MeshyPlacementSource.webGlb(glbUrl),
      isPersisted: false,
      thumbnailUrl: thumbnailUrl,
      originalGlbUrl: glbUrl,
    );
  }

  MeshyActiveModel? fallbackAfterPlacementFailure() {
    final fallbackSource = retryPlacementSource;
    if (fallbackSource == null) {
      return null;
    }

    return MeshyActiveModel._(
      id: id,
      prompt: prompt,
      placementSource: fallbackSource,
      isPersisted: isPersisted,
      localRelativePath: localRelativePath,
      thumbnailUrl: thumbnailUrl,
      originalGlbUrl: originalGlbUrl,
    );
  }

  static _PlacementSourceSelection _selectPlacementSources({
    required MeshyPlacementRuntime runtime,
    required MeshyPlacementSource localSource,
    required MeshyPlacementSource? remoteSource,
  }) {
    switch (runtime) {
      case MeshyPlacementRuntime.android:
        return _PlacementSourceSelection(primary: remoteSource ?? localSource);
      case MeshyPlacementRuntime.iOS:
        return _PlacementSourceSelection(
          primary: localSource,
          retry: remoteSource,
        );
      case MeshyPlacementRuntime.other:
        return _PlacementSourceSelection(
          primary: remoteSource ?? localSource,
          retry: remoteSource == null ? null : localSource,
        );
    }
  }
}

class _PlacementSourceSelection {
  const _PlacementSourceSelection({required this.primary, this.retry});

  final MeshyPlacementSource primary;
  final MeshyPlacementSource? retry;
}

class MeshyModelHistoryCacheResult {
  const MeshyModelHistoryCacheResult({
    required this.record,
    required this.activeModel,
  });

  final MeshyModelRecord record;
  final MeshyActiveModel activeModel;
}

class MeshyModelHistoryStore {
  MeshyModelHistoryStore({
    Future<Directory> Function()? documentsDirectoryLoader,
    HttpClient? httpClient,
    this.maxEntries = defaultMeshyModelHistoryLimit,
  }) : _documentsDirectoryLoader =
           documentsDirectoryLoader ?? getApplicationDocumentsDirectory,
       _httpClient = httpClient ?? HttpClient();

  final Future<Directory> Function() _documentsDirectoryLoader;
  final HttpClient _httpClient;
  final int maxEntries;

  Future<List<MeshyModelRecord>> loadRecords() async {
    final records = await _readIndexRecords();
    final validRecords = <MeshyModelRecord>[];
    for (final record in records) {
      final file = await _recordFile(record);
      if (await file.exists()) {
        validRecords.add(record);
      }
    }

    final sortedRecords = _sortRecords(validRecords);
    final prunedRecords = sortedRecords
        .take(maxEntries)
        .toList(growable: false);
    if (validRecords.length != records.length ||
        prunedRecords.length != records.length) {
      await _deletePrunedFiles(sortedRecords.skip(maxEntries));
      await _writeIndexRecords(prunedRecords);
    }
    return prunedRecords;
  }

  Future<MeshyModelHistoryCacheResult> cacheCompletedJob({
    required MeshyGenerationJob job,
  }) async {
    final glbUrl = job.glbUrl?.trim() ?? '';
    if (glbUrl.isEmpty) {
      throw const MeshyModelHistoryException(
        'Meshy did not return a valid GLB URL to cache.',
      );
    }

    final id = job.jobId.trim();
    if (id.isEmpty) {
      throw const MeshyModelHistoryException(
        'Meshy did not return a valid job id for model caching.',
      );
    }

    final relativePath = '$_modelCacheDirectoryName/$id.glb';
    final targetFile = await _recordFile(
      MeshyModelRecord(
        id: id,
        prompt: job.prompt,
        localRelativePath: relativePath,
        originalGlbUrl: glbUrl,
        thumbnailUrl: job.thumbnailUrl,
        createdAt: job.createdAt ?? DateTime.now().toUtc(),
        updatedAt: job.updatedAt ?? DateTime.now().toUtc(),
        lastUsedAt: DateTime.now().toUtc(),
      ),
    );
    await targetFile.parent.create(recursive: true);
    await _downloadToFile(Uri.parse(glbUrl), targetFile);

    final now = DateTime.now().toUtc();
    final record = MeshyModelRecord(
      id: id,
      prompt: job.prompt,
      localRelativePath: relativePath,
      originalGlbUrl: glbUrl,
      thumbnailUrl: job.thumbnailUrl,
      createdAt: job.createdAt ?? now,
      updatedAt: job.updatedAt ?? now,
      lastUsedAt: now,
    );

    final existingRecords = await loadRecords();
    final nextRecords = _sortRecords(<MeshyModelRecord>[
      record,
      ...existingRecords.where((item) => item.id != record.id),
    ]);
    final retainedRecords = nextRecords
        .take(maxEntries)
        .toList(growable: false);
    await _deletePrunedFiles(nextRecords.skip(maxEntries));
    await _writeIndexRecords(retainedRecords);

    return MeshyModelHistoryCacheResult(
      record: record,
      activeModel: MeshyActiveModel.fromRecord(
        record,
        runtime: detectMeshyPlacementRuntime(),
      ),
    );
  }

  Future<void> markUsed(String id) async {
    final records = await loadRecords();
    final index = records.indexWhere((record) => record.id == id);
    if (index == -1) {
      return;
    }

    final nextRecords = <MeshyModelRecord>[...records];
    nextRecords[index] = nextRecords[index].copyWith(
      lastUsedAt: DateTime.now().toUtc(),
    );
    await _writeIndexRecords(nextRecords);
  }

  void close() {
    _httpClient.close(force: true);
  }

  Future<File> _recordFile(MeshyModelRecord record) async {
    final documentsDirectory = await _documentsDirectoryLoader();
    return File('${documentsDirectory.path}/${record.localRelativePath}');
  }

  Future<List<MeshyModelRecord>> _readIndexRecords() async {
    final indexFile = await _indexFile();
    if (!await indexFile.exists()) {
      return const <MeshyModelRecord>[];
    }

    try {
      final rawContents = await indexFile.readAsString();
      if (rawContents.trim().isEmpty) {
        return const <MeshyModelRecord>[];
      }

      final decoded = jsonDecode(rawContents);
      if (decoded is! Map<String, dynamic>) {
        throw const MeshyModelHistoryException(
          'The model history index is invalid.',
        );
      }

      final rawRecords = decoded['records'];
      if (rawRecords is! List) {
        return const <MeshyModelRecord>[];
      }

      final records = <MeshyModelRecord>[];
      for (final rawRecord in rawRecords) {
        if (rawRecord is! Map<String, dynamic>) {
          continue;
        }
        try {
          records.add(MeshyModelRecord.fromJson(rawRecord));
        } on MeshyModelHistoryException {
          continue;
        }
      }
      return records;
    } on FileSystemException catch (error) {
      throw MeshyModelHistoryException(
        'Failed to read the local model history: $error',
      );
    } on FormatException catch (error) {
      throw MeshyModelHistoryException(
        'Failed to parse the local model history: $error',
      );
    }
  }

  Future<void> _writeIndexRecords(List<MeshyModelRecord> records) async {
    final indexFile = await _indexFile();
    await indexFile.parent.create(recursive: true);
    await indexFile.writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'records': records.map((record) => record.toJson()).toList(),
      }),
      flush: true,
    );
  }

  Future<File> _indexFile() async {
    final documentsDirectory = await _documentsDirectoryLoader();
    return File(
      '${documentsDirectory.path}/$_modelCacheDirectoryName/$_modelHistoryIndexFileName',
    );
  }

  List<MeshyModelRecord> _sortRecords(List<MeshyModelRecord> records) {
    final nextRecords = <MeshyModelRecord>[...records];
    nextRecords.sort((left, right) {
      final createdComparison = right.createdAt.compareTo(left.createdAt);
      if (createdComparison != 0) {
        return createdComparison;
      }
      return right.updatedAt.compareTo(left.updatedAt);
    });
    return nextRecords;
  }

  Future<void> _downloadToFile(Uri uri, File targetFile) async {
    final request = await _httpClient.getUrl(uri);
    final response = await request.close();
    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      throw MeshyModelHistoryException(
        'Downloading the generated GLB failed with HTTP ${response.statusCode}.',
      );
    }

    final bytes = await response.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    await targetFile.writeAsBytes(bytes, flush: true);
  }

  Future<void> _deletePrunedFiles(Iterable<MeshyModelRecord> records) async {
    for (final record in records) {
      final file = await _recordFile(record);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}
