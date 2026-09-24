// 2 台の実機で Drive 同期を往復させるための、PC 上の偽 Drive（HTTP）。
//
// 端末からは `adb reverse tcp:8799 tcp:8799` で 127.0.0.1:8799 に見える。
// 中身は test/support/fake_google_drive.dart と同じ振る舞い（同名は上書き、modifiedTime は単調増加）を
// サーバーの時計で付ける。端末どうしの手順合わせ（バリア）と結果の報告も受ける。
//
// 使い方: dart run tool/sync_relay/relay_server.dart [port]
// テスト: integration_test/geodiff_two_device_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class _Item {
  _Item(this.id, this.name, this.parentId, {this.isFolder = false, Uint8List? bytes, DateTime? modified})
      : bytes = bytes ?? Uint8List(0),
        modified = modified ?? DateTime.now().toUtc();
  final String id;
  String name;
  String? parentId;
  final bool isFolder;
  Uint8List bytes;
  DateTime modified;
  bool trashed = false;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'mimeType': isFolder ? 'application/vnd.google-apps.folder' : 'application/octet-stream',
        'modifiedTime': modified.toIso8601String(),
        'size': isFolder ? null : '${bytes.length}',
        'parents': parentId == null ? null : [parentId],
        'trashed': trashed,
      };
}

final _items = <String, _Item>{};
var _seq = 0;
var _last = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
final _done = <String>{};
final _reports = <String, Object?>{};

String _newId() => 'relay${++_seq}';

DateTime _stamp() {
  var now = DateTime.now().toUtc();
  if (!now.isAfter(_last)) now = _last.add(const Duration(milliseconds: 1));
  _last = now;
  return now;
}

Iterable<_Item> _children(String parent) => _items.values.where((i) => i.parentId == parent && !i.trashed);

_Item? _byName(String parent, String name) {
  for (final i in _children(parent)) {
    if (i.name == name) return i;
  }
  return null;
}

Object? _handle(Map<String, dynamic> r) {
  final op = r['op'] as String;
  switch (op) {
    case 'reset':
      _items.clear();
      _done.clear();
      _reports.clear();
      return true;
    case 'createRootFolder':
      final existing = _items.values.where((i) => i.parentId == null && i.name == r['name'] && !i.trashed);
      if (existing.isNotEmpty) return existing.first.id;
      final id = _newId();
      _items[id] = _Item(id, r['name'] as String, null, isFolder: true);
      return id;
    case 'getFolderInfo':
      final f = _items[r['id']];
      return f == null || f.trashed ? null : f.toJson();
    case 'listFiles':
      return _children(r['parentId'] as String).map((i) => i.toJson()).toList();
    case 'getOrCreateSubFolder':
      final e = _byName(r['parentId'] as String, r['name'] as String);
      if (e != null && e.isFolder) return e.toJson();
      final id = _newId();
      _items[id] = _Item(id, r['name'] as String, r['parentId'] as String, isFolder: true);
      return _items[id]!.toJson();
    case 'uploadBytes':
      final bytes = base64Decode(r['bytes'] as String);
      final parent = r['parentId'] as String;
      final name = r['name'] as String;
      final existingId = r['existingFileId'] as String?;
      var target = existingId == null ? null : _items[existingId];
      if (target != null && target.trashed) target = null;
      target ??= _byName(parent, name);
      if (target != null && !target.isFolder) {
        target
          ..bytes = bytes
          ..name = name
          ..modified = _stamp();
        return target.toJson();
      }
      final id = _newId();
      _items[id] = _Item(id, name, parent, bytes: bytes, modified: _stamp());
      return _items[id]!.toJson();
    case 'download':
      final f = _items[r['id']];
      if (f == null || f.isFolder || f.trashed) return null;
      return base64Encode(f.bytes);
    case 'delete':
      final f = _items[r['id']];
      if (f == null) return false;
      f.trashed = true;
      return true;
    case 'getFileMetadata':
      return _items[r['id']]?.toJson();
    case 'moveFile':
      final f = _items[r['id']];
      if (f == null) return false;
      f.parentId = r['newParentId'] as String;
      return true;
    case 'done':
      _done.add(r['step'] as String);
      stdout.writeln('[relay] ${DateTime.now().toIso8601String()} done ${r['step']}');
      return true;
    case 'isDone':
      return _done.contains(r['step']);
    case 'report':
      _reports[r['role'] as String] = r['data'];
      stdout.writeln('[relay] report ${r['role']}: ${jsonEncode(r['data'])}');
      return true;
    case 'reports':
      return _reports;
    case 'now':
      return DateTime.now().toUtc().toIso8601String();
  }
  throw ArgumentError('unknown op $op');
}

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 8799 : int.parse(args.first);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('[relay] listening on 127.0.0.1:$port');
  await for (final req in server) {
    try {
      final body = await utf8.decodeStream(req);
      final r = jsonDecode(body) as Map<String, dynamic>;
      final result = _handle(r);
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true, 'result': result}));
    } catch (e) {
      req.response
        ..statusCode = 500
        ..write(jsonEncode({'ok': false, 'error': '$e'}));
    }
    await req.response.close();
  }
}
