// 同期層のテスト用に、GoogleDriveService をメモリ上の Drive で置き換える。
//
// GoogleDriveService は private コンストラクタのシングルトンなので extends できない。
// implements + noSuchMethod で、同期層が呼ぶメソッドだけ本物らしく振る舞わせる
// （呼ばれていないメソッドを呼ぶと NoSuchMethodError で落ちる＝使われ方の変化に気づける）。
import 'dart:io';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:root_maps/services/google_drive/google_drive_service.dart';

const _folderMime = 'application/vnd.google-apps.folder';

class FakeDriveItem {
  FakeDriveItem({
    required this.id,
    required this.name,
    required this.parentId,
    this.isFolder = false,
    Uint8List? bytes,
    DateTime? modifiedTime,
  })  : bytes = bytes ?? Uint8List(0),
        modifiedTime = modifiedTime ?? DateTime.now();

  final String id;
  String name;
  String? parentId;
  final bool isFolder;
  Uint8List bytes;
  DateTime modifiedTime;
  bool trashed = false;

  drive.File toFile() => drive.File(
        id: id,
        name: name,
        mimeType: isFolder ? _folderMime : 'application/octet-stream',
        modifiedTime: modifiedTime,
        size: isFolder ? null : '${bytes.length}',
        parents: parentId == null ? null : [parentId!],
      );
}

class FakeGoogleDrive implements GoogleDriveService {
  final Map<String, FakeDriveItem> items = {};
  int _seq = 0;

  /// 呼ばれた回数（どの経路を通ったかの確認用）
  final Map<String, int> calls = {};

  void _count(String name) => calls[name] = (calls[name] ?? 0) + 1;

  String _newId() => 'fake${++_seq}';

  /// Drive サーバーの時計と端末の時計のずれ（サーバー = 端末 + [serverClockOffset]）。
  /// 負なら端末の時計が進んでいる
  Duration serverClockOffset = Duration.zero;

  /// 次の書き込みで付ける時刻。単調増加にする（同じミリ秒で並ぶと「変更あり」を判定できない）
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _stamp() {
    var now = DateTime.now().add(serverClockOffset);
    if (!now.isAfter(_last)) now = _last.add(const Duration(milliseconds: 1));
    _last = now;
    return now;
  }

  /// テスト用: ルート直下にフォルダを作る
  String createRootFolder(String name) {
    final id = _newId();
    items[id] = FakeDriveItem(id: id, name: name, parentId: null, isFolder: true);
    return id;
  }

  Iterable<FakeDriveItem> childrenOf(String parentId) =>
      items.values.where((i) => i.parentId == parentId && !i.trashed);

  FakeDriveItem? findByName(String parentId, String name) {
    for (final i in childrenOf(parentId)) {
      if (i.name == name) return i;
    }
    return null;
  }

  /// テスト用: 相対パスでファイルを引く
  FakeDriveItem? fileAt(String rootId, String relativePath) {
    var parent = rootId;
    final parts = relativePath.split('/');
    for (var i = 0; i < parts.length - 1; i++) {
      final f = findByName(parent, parts[i]);
      if (f == null || !f.isFolder) return null;
      parent = f.id;
    }
    final f = findByName(parent, parts.last);
    return f == null || f.isFolder ? null : f;
  }

  /// テスト用: 全ファイルの相対パス
  List<String> allPaths(String rootId, [String prefix = '']) {
    final out = <String>[];
    for (final c in childrenOf(rootId)) {
      final path = prefix.isEmpty ? c.name : '$prefix/${c.name}';
      if (c.isFolder) {
        out.addAll(allPaths(c.id, path));
      } else {
        out.add(path);
      }
    }
    return out..sort();
  }

  // ---- 同期層が使う面 ----

  @override
  bool get isDriveApiAvailable => true;

  @override
  Future<drive.File?> getFolderInfo(String folderId) async {
    _count('getFolderInfo');
    final f = items[folderId];
    return f == null || f.trashed ? null : f.toFile();
  }

  @override
  Future<List<drive.File>> listFiles(String parentId) async {
    _count('listFiles');
    return childrenOf(parentId).map((i) => i.toFile()).toList();
  }

  @override
  Future<drive.File?> getOrCreateSubFolder(String parentId, String folderName) async {
    _count('getOrCreateSubFolder');
    final existing = findByName(parentId, folderName);
    if (existing != null && existing.isFolder) return existing.toFile();
    final id = _newId();
    items[id] = FakeDriveItem(id: id, name: folderName, parentId: parentId, isFolder: true);
    return items[id]!.toFile();
  }

  @override
  Future<drive.File?> createProjectFolder(String name, {String? parentId}) async {
    _count('createProjectFolder');
    final id = _newId();
    items[id] = FakeDriveItem(id: id, name: name, parentId: parentId, isFolder: true);
    return items[id]!.toFile();
  }

  @override
  Future<drive.File?> uploadBytes(Uint8List bytes, String fileName, String parentId) async {
    _count('uploadBytes');
    final existing = findByName(parentId, fileName);
    if (existing != null && !existing.isFolder) {
      existing
        ..bytes = Uint8List.fromList(bytes)
        ..modifiedTime = _stamp();
      return existing.toFile();
    }
    final id = _newId();
    items[id] = FakeDriveItem(
      id: id,
      name: fileName,
      parentId: parentId,
      bytes: Uint8List.fromList(bytes),
      modifiedTime: _stamp(),
    );
    return items[id]!.toFile();
  }

  @override
  Future<drive.File?> uploadFile(
    String localPath,
    String parentId, {
    void Function(double progress)? onProgress,
  }) async {
    _count('uploadFile');
    return uploadBytes(await File(localPath).readAsBytes(), p.basename(localPath), parentId);
  }

  @override
  Future<drive.File?> uploadFileById(
    String localPath,
    String parentId, {
    String? existingFileId,
  }) async {
    _count('uploadFileById');
    final bytes = await File(localPath).readAsBytes();
    final existing = existingFileId == null ? null : items[existingFileId];
    if (existing != null && !existing.trashed) {
      existing
        ..bytes = bytes
        ..name = p.basename(localPath)
        ..modifiedTime = _stamp();
      return existing.toFile();
    }
    return uploadBytes(bytes, p.basename(localPath), parentId);
  }

  @override
  Future<bool> downloadFile(
    String fileId,
    String localPath, {
    void Function(double progress)? onProgress,
  }) async {
    _count('downloadFile');
    final f = items[fileId];
    if (f == null || f.isFolder || f.trashed) return false;
    await File(localPath).parent.create(recursive: true);
    await File(localPath).writeAsBytes(f.bytes, flush: true);
    return true;
  }

  @override
  Future<bool> deleteFile(String fileId) async {
    _count('deleteFile');
    final f = items[fileId];
    if (f == null) return false;
    f.trashed = true;
    return true;
  }

  @override
  Future<DriveFileMetadata?> getFileMetadata(String fileId) async {
    _count('getFileMetadata');
    final f = items[fileId];
    if (f == null) return null;
    return DriveFileMetadata(
      id: f.id,
      name: f.name,
      trashed: f.trashed,
      modifiedTime: f.modifiedTime,
      parents: f.parentId == null ? const [] : [f.parentId!],
    );
  }

  @override
  Future<bool> moveFile(String fileId, {required String newParentId, String? oldParentId}) async {
    _count('moveFile');
    final f = items[fileId];
    if (f == null) return false;
    f.parentId = newParentId;
    return true;
  }

  /// テスト用: 別の端末が Drive 上のファイルを書き換えたことにする
  void touch(String fileId, Uint8List bytes) {
    items[fileId]!
      ..bytes = bytes
      ..modifiedTime = _stamp();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
