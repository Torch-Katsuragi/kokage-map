// 地物の写真: 置き場所・列の決まり（FeaturePhotoPaths）と、付ける・外す（FeaturePhotoService）
//
// 付ける・外すは実物の GeoPackage で確かめる（feature_node_create_update_test.dart と同じ作り）。
import 'dart:io';

import 'package:exif/exif.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/external_layer_node.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/feature_photos/feature_photo_paths.dart';
import 'package:root_maps/services/feature_photos/feature_photo_service.dart';
import 'package:root_maps/services/google_drive/sync_file_operations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_google_drive.dart';

void main() {
  group('置き場所と列の決まり', () {
    test('ファイル名は撮った日時と fid', () {
      expect(FeaturePhotoPaths.fileName(DateTime(2026, 10, 1, 9, 5, 7), 12), '20261001_090507_12.jpg');
      expect(FeaturePhotoPaths.fileName(DateTime(2026, 1, 2, 3, 4, 5), 3, ext: '.PNG'), '20260102_030405_3.png');
    });

    test('相対パスは photos/<レイヤ>/…（区切りは /、使えない文字は _）', () {
      expect(FeaturePhotoPaths.relativePath('林小班', 'a.jpg'), 'photos/林小班/a.jpg');
      expect(FeaturePhotoPaths.relativePath('a/b:c*', 'x.jpg'), 'photos/a_b_c_/x.jpg');
      expect(FeaturePhotoPaths.relativePath('末尾. ', 'x.jpg'), 'photos/末尾/x.jpg');
    });

    test('重なったら _1, _2 を足す', () {
      final taken = {'photos/a/x.jpg', 'photos/a/x_1.jpg'};
      expect(FeaturePhotoPaths.uniqueRelative('photos/a/x.jpg', taken.contains), 'photos/a/x_2.jpg');
      expect(FeaturePhotoPaths.uniqueRelative('photos/a/y.jpg', taken.contains), 'photos/a/y.jpg');
    });

    test('相対パスは gpkg の dir から解く。絶対パスはそのまま', () {
      final dir = p.join('root', 'sub');
      expect(FeaturePhotoPaths.resolve(dir, 'photos/a/x.jpg'), p.join('root', 'sub', 'photos', 'a', 'x.jpg'));
      expect(FeaturePhotoPaths.resolve(dir, r'photos\a\x.jpg'), p.join('root', 'sub', 'photos', 'a', 'x.jpg'));
      expect(FeaturePhotoPaths.resolve(dir, '../x.jpg'), p.join('root', 'x.jpg'));
    });

    test('写真の列は photo・photo_2…（photo_1・photo_x・photos は違う）', () {
      expect(FeaturePhotoPaths.isPhotoColumn('photo'), isTrue);
      expect(FeaturePhotoPaths.isPhotoColumn('Photo_3'), isTrue);
      expect(FeaturePhotoPaths.isPhotoColumn('photo_1'), isFalse);
      expect(FeaturePhotoPaths.isPhotoColumn('photo_x'), isFalse);
      expect(FeaturePhotoPaths.isPhotoColumn('photos'), isFalse);
      expect(FeaturePhotoPaths.columnAt(0), 'photo');
      expect(FeaturePhotoPaths.columnAt(2), 'photo_3');
    });

    test('次の列: 空いている写真の列 → 無ければ次の番号を作る', () {
      expect(FeaturePhotoPaths.nextColumn(['fid', 'name'], {}), (column: 'photo', create: true));
      expect(FeaturePhotoPaths.nextColumn(['photo'], {'photo': ''}), (column: 'photo', create: false));
      expect(FeaturePhotoPaths.nextColumn(['photo'], {'photo': 'a.jpg'}), (column: 'photo_2', create: true));
      expect(
        FeaturePhotoPaths.nextColumn(['photo_2', 'photo'], {'photo': 'a.jpg', 'photo_2': null}),
        (column: 'photo_2', create: false),
      );
    });

    test('付いている写真は列の順（空は飛ばす）', () {
      final links = FeaturePhotoPaths.linksOf({'photo_3': 'c.jpg', 'name': 'x', 'photo': 'a.jpg', 'photo_2': ' '});
      expect([for (final l in links) l.column], ['photo', 'photo_3']);
    });
  });

  group('付ける・外す（GeoPackage）', () {
    late Directory tmp;
    late GeoPackageFile gpkg;
    late GeoPackageNode gpkgNode;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('feature_photo_');
      gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: p.join(tmp.path, 't.gpkg'));
      gpkgNode = GeoPackageNode(gpkg);
    });

    tearDown(() async {
      await gpkg.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    final jpeg = img.encodeJpg(img.Image(width: 8, height: 8));
    const fix = LatLng(33.9, 135.9);

    test('撮った写真を photos/<レイヤ>/ に置き、photo 列（無ければ作る）に相対パスを書く', () async {
      final layer = (await PointLayerNode.createIn(gpkgNode, 'pts'))!;
      final f = (await PointFeatureNode.createIn(layer, fix, 'p1', null))!;
      expect(await gpkg.getColumnNames('pts', getAll: true), isNot(contains('photo')));

      final first = (await FeaturePhotoService.attachBytes(f, jpeg, fix: fix, takenAt: DateTime(2026, 10, 11, 9, 30)))!;
      expect(first.column, 'photo');
      expect(first.value, 'photos/pts/20261011_093000_${f.rowId}.jpg');
      expect(File(p.join(tmp.path, 'photos', 'pts', '20261011_093000_${f.rowId}.jpg')).existsSync(), isTrue);
      // カメラが位置を書いていなければ今の位置が入る
      final tags = await readExifFromBytes(File(first.path).readAsBytesSync());
      expect(tags['GPS GPSLatitude'], isNotNull);
      expect(await gpkg.getColumnNames('pts', getAll: true), contains('photo'));

      // 同じ秒にもう 1 枚 → 名前に _1、列は photo_2 を作る
      final second = (await FeaturePhotoService.attachBytes(f, jpeg, takenAt: DateTime(2026, 10, 11, 9, 30)))!;
      expect(second.column, 'photo_2');
      expect(second.value, 'photos/pts/20261011_093000_${f.rowId}_1.jpg');
      expect([for (final ph in FeaturePhotoService.photosOf(f)) ph.column], ['photo', 'photo_2']);

      // 読み直しても値が残っている（DB に書けている）
      await layer.updateChildren();
      final reloaded = layer.children.whereType<PointFeatureNode>().single;
      expect(reloaded.turfFeature.properties?['photo'], first.value);
      expect(reloaded.turfFeature.properties?['photo_2'], second.value);
    });

    // 写真（新しく）× 読み取り専用レイヤ（shp など。中身は .kokage/cache の下のキャッシュ gpkg で読む）。
    // 写真の相対パスは元のファイルの dir から解く（QGIS と同じ）。キャッシュの dir から解くと写真が出ない
    test('読み取り専用レイヤの写真は元のファイルの dir から解く', () async {
      final source = p.join(tmp.path, 'survey', '立木.shp');
      final external = ExternalLayerNode(source);
      final cache = external.geoPackageFile;
      final layer = PointLayerNode(cache, 'pts', parent: external);
      external.children.add(layer);
      final cachePath = cache.getAbsolutePath()!;
      expect(p.dirname(cachePath), isNot(p.dirname(source)), reason: 'キャッシュは .kokage/cache の下');
      await cache.addLayer('pts', GeometryType.point);
      await cache.addAttributeColumns('pts', {'photo': 'TEXT'});
      await cache.addPointWithAttributes('pts', fix, {'photo': 'photos/pts/a.jpg'});
      await cache.flushChanges();
      await layer.updateChildren();
      final f = layer.children.whereType<PointFeatureNode>().single;

      expect(FeaturePhotoService.gpkgDirOf(f), p.join(tmp.path, 'survey'));
      expect(FeaturePhotoService.photosOf(f).single.path, p.join(tmp.path, 'survey', 'photos', 'pts', 'a.jpg'));
      await cache.dispose();
    });

    test('外す: 列を空にする。ファイルも消すを選べば消す。次の写真は空いた列に入る', () async {
      final layer = (await PointLayerNode.createIn(gpkgNode, 'pts'))!;
      final f = (await PointFeatureNode.createIn(layer, fix, 'p1', null))!;
      final a = (await FeaturePhotoService.attachBytes(f, jpeg, takenAt: DateTime(2026, 10, 11, 9)))!;
      final b = (await FeaturePhotoService.attachBytes(f, jpeg, takenAt: DateTime(2026, 10, 11, 10)))!;

      await FeaturePhotoService.unlink(f, a);
      expect(File(a.path).existsSync(), isTrue);
      expect([for (final ph in FeaturePhotoService.photosOf(f)) ph.column], ['photo_2']);

      await FeaturePhotoService.unlink(f, b, deleteFile: true);
      expect(File(b.path).existsSync(), isFalse);
      expect(FeaturePhotoService.photosOf(f), isEmpty);

      final c = (await FeaturePhotoService.attachBytes(f, jpeg, takenAt: DateTime(2026, 10, 11, 11)))!;
      expect(c.column, 'photo');
      expect((await gpkg.getColumnNames('pts', getAll: true)).where(FeaturePhotoPaths.isPhotoColumn), hasLength(2));
    });

    // 2026-10-11 夜のレビュー: 「外して消す」が photos/ の外（QGIS の絶対パス・../）や、
    // 複製したレイヤが共有している写真まで消していた
    test('外して消す: photos/ の外の写真と、ほかの地物も指している写真は消さない', () async {
      final layer = (await PointLayerNode.createIn(gpkgNode, 'pts'))!;
      final f = (await PointFeatureNode.createIn(layer, fix, 'p1', null))!;
      final g = (await PointFeatureNode.createIn(layer, fix, 'p2', null))!;

      // 外の写真（../DCIM/…）
      final outside = File(p.join(tmp.path, '..', '${p.basename(tmp.path)}_dcim.jpg'))..writeAsBytesSync(jpeg);
      addTearDown(() => outside.existsSync() ? outside.deleteSync() : null);
      await FeaturePhotoService.link(f, '../${p.basename(outside.path)}');
      final out = FeaturePhotoService.photosOf(f).single;
      expect(await FeaturePhotoService.unlink(f, out, deleteFile: true), isFalse);
      expect(outside.existsSync(), isTrue);
      expect(FeaturePhotoService.photosOf(f), isEmpty, reason: 'リンクは外す');

      // 2 つの地物が同じ写真を指す（レイヤの複製など）
      final shared = (await FeaturePhotoService.attachBytes(f, jpeg, takenAt: DateTime(2026, 10, 11, 9)))!;
      await FeaturePhotoService.link(g, shared.value);
      expect(await FeaturePhotoService.unlink(f, shared, deleteFile: true), isFalse);
      expect(File(shared.path).existsSync(), isTrue);

      // 最後の 1 つを外せば消す
      final last = FeaturePhotoService.photosOf(g).single;
      expect(await FeaturePhotoService.unlink(g, last, deleteFile: true), isTrue);
      expect(File(shared.path).existsSync(), isFalse);
    });

    test('写真の列を作ったら、レイヤの列名のキャッシュを捨てる', () async {
      final layer = (await PointLayerNode.createIn(gpkgNode, 'pts'))!;
      final f = (await PointFeatureNode.createIn(layer, fix, 'p1', null))!;
      expect(await layer.getAttributeColumnNames(getAll: true), isNot(contains('photo')));
      await FeaturePhotoService.attachBytes(f, jpeg);
      expect(await layer.getAttributeColumnNames(getAll: true), contains('photo'));
    });

    test('既にある photo 列（QGIS で作ったもの）にも書く', () async {
      final layer = (await PointLayerNode.createIn(gpkgNode, 'pts'))!;
      await gpkg.addAttributeColumns('pts', {'photo': 'TEXT'});
      final f = (await PointFeatureNode.createIn(layer, fix, 'p1', null))!;
      final ph = await FeaturePhotoService.link(f, 'photos/pts/x.jpg');
      expect(ph, 'photo');
      expect(f.turfFeature.properties?['photo'], 'photos/pts/x.jpg');
    });
  });

  test('アプリが作った写真の列はフォルダ設定に残る（.qgs に写真の欄を書く印）', () {
    const meta = KMeta(photoFields: {'調査.gpkg/pts': ['photo', 'photo_2']});
    final back = KMeta.fromJson(meta.toJson());
    expect(back.photoFields, {'調査.gpkg/pts': ['photo', 'photo_2']});
    expect(back.isEmpty, isFalse);
    expect(const KMeta().toJson().containsKey('photoFields'), isFalse);
  });

  test('Drive 同期: photos/<レイヤ>/ の写真も上げる対象', () async {
    final tmp = await Directory.systemTemp.createTemp('feature_photo_sync_');
    try {
      File(p.join(tmp.path, 'photos', 'pts', 'a.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([0xFF, 0xD8]);
      final ops = SyncFileOperations(driveService: FakeGoogleDrive());
      final rel = [for (final e in await ops.listLocalSyncFiles(tmp.path)) e.relativePath.replaceAll(r'\', '/')];
      expect(rel, contains('photos/pts/a.jpg'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
