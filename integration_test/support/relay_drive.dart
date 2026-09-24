// tool/sync_relay/relay_server.dart（PC 上の偽 Drive）を GoogleDriveService として使う。
// 2 台の実機で同期を往復させるテスト用。端末からは adb reverse で 127.0.0.1 に見える。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:root_maps/services/google_drive/google_drive_service.dart';

class RelayClient {
  RelayClient({this.host = '127.0.0.1', this.port = 8799});
  final String host;
  final int port;
  final _http = HttpClient();

  Future<Object?> call(String op, [Map<String, Object?> args = const {}]) async {
    final req = await _http.post(host, port, '/rpc');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'op': op, ...args}));
    final res = await req.close();
    final body = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
    if (body['ok'] != true) throw StateError('relay $op: ${body['error']}');
    return body['result'];
  }

  /// 相手の端末が [step] を終えるまで待つ
  Future<void> waitFor(String step, {Duration timeout = const Duration(minutes: 25)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (await call('isDone', {'step': step}) == true) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw StateError('相手の端末が $step を終えない（${timeout.inMinutes} 分）');
  }

  Future<void> done(String step) => call('done', {'step': step});
}

drive.File _file(Object? json) {
  final m = json! as Map<String, dynamic>;
  return drive.File(
    id: m['id'] as String?,
    name: m['name'] as String?,
    mimeType: m['mimeType'] as String?,
    modifiedTime: m['modifiedTime'] == null ? null : DateTime.parse(m['modifiedTime'] as String),
    size: m['size'] as String?,
    parents: (m['parents'] as List?)?.cast<String>(),
  );
}

class RelayGoogleDrive implements GoogleDriveService {
  RelayGoogleDrive(this.relay);
  final RelayClient relay;

  @override
  bool get isDriveApiAvailable => true;

  @override
  Future<drive.File?> getFolderInfo(String folderId) async {
    final r = await relay.call('getFolderInfo', {'id': folderId});
    return r == null ? null : _file(r);
  }

  @override
  Future<List<drive.File>> listFiles(String parentId) async =>
      ((await relay.call('listFiles', {'parentId': parentId})) as List? ?? const []).map(_file).toList();

  @override
  Future<drive.File?> getOrCreateSubFolder(String parentId, String folderName) async =>
      _file(await relay.call('getOrCreateSubFolder', {'parentId': parentId, 'name': folderName}));

  @override
  Future<drive.File?> uploadBytes(Uint8List bytes, String fileName, String parentId) async =>
      _file(await relay.call('uploadBytes', {'bytes': base64Encode(bytes), 'name': fileName, 'parentId': parentId}));

  @override
  Future<drive.File?> uploadFile(String localPath, String parentId, {void Function(double progress)? onProgress}) async =>
      uploadBytes(await File(localPath).readAsBytes(), p.basename(localPath), parentId);

  @override
  Future<drive.File?> uploadFileById(String localPath, String parentId, {String? existingFileId}) async =>
      _file(await relay.call('uploadBytes', {
        'bytes': base64Encode(await File(localPath).readAsBytes()),
        'name': p.basename(localPath),
        'parentId': parentId,
        'existingFileId': existingFileId,
      }));

  @override
  Future<bool> downloadFile(String fileId, String localPath, {void Function(double progress)? onProgress}) async {
    final b64 = await relay.call('download', {'id': fileId});
    if (b64 == null) return false;
    await File(localPath).parent.create(recursive: true);
    await File(localPath).writeAsBytes(base64Decode(b64 as String), flush: true);
    return true;
  }

  @override
  Future<bool> deleteFile(String fileId) async => await relay.call('delete', {'id': fileId}) == true;

  @override
  Future<DriveFileMetadata?> getFileMetadata(String fileId) async {
    final r = await relay.call('getFileMetadata', {'id': fileId});
    if (r == null) return null;
    final m = r as Map<String, dynamic>;
    return DriveFileMetadata(
      id: m['id'] as String,
      name: m['name'] as String?,
      trashed: m['trashed'] as bool? ?? false,
      modifiedTime: m['modifiedTime'] == null ? null : DateTime.parse(m['modifiedTime'] as String),
      parents: (m['parents'] as List?)?.cast<String>() ?? const [],
    );
  }

  @override
  Future<bool> moveFile(String fileId, {required String newParentId, String? oldParentId}) async =>
      await relay.call('moveFile', {'id': fileId, 'newParentId': newParentId}) == true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
