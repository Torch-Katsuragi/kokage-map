// 両方の端末で変わった `.qgs` のフォルダ設定を 3-way で合わせる（QgsMerger、2026-09-29）。
// 設定が Drive で共有されるようになったので、2 台で別々に表示やスタイルを変えると `.qgs` が衝突する。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/services/google_drive/qgs_merger.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/sync_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_google_drive.dart';

void main() {
  group('JSON の 3-way', () {
    Object? m(Object? b, Object? mine, Object? t, [List<String>? c]) =>
        QgsMerger.merge3(b, mine, t, '', c ?? <String>[]);

    test('別々のキーの変更は両方残る', () {
      expect(
        m({'a': 1, 'b': 1}, {'a': 2, 'b': 1}, {'a': 1, 'b': 3}),
        {'a': 2, 'b': 3},
      );
    });

    test('入れ子の辞書もキーごと（別々のレイヤの可視性）', () {
      final r = m(
        {'visibility': {'layers': <String, Object?>{}}},
        {'visibility': {'layers': {'x/x': false}}},
        {'visibility': {'layers': {'y/y': false}}},
      );
      expect(r, {'visibility': {'layers': {'x/x': false, 'y/y': false}}});
    });

    test('同じキーを別の値にしたら、この端末の値と衝突の道筋', () {
      final c = <String>[];
      expect(m({'a': 1}, {'a': 2}, {'a': 3}, c), {'a': 2});
      expect(c, ['a']);
    });

    test('片側が消したキーは消える。もう片側が同じキーを変えていたら衝突（この端末の値）', () {
      expect(m({'a': 1, 'b': 1}, {'b': 1}, {'a': 1, 'b': 1}), {'b': 1});
      final c = <String>[];
      expect(m({'a': 1}, <String, Object?>{}, {'a': 5}, c), <String, Object?>{});
      expect(c, ['a']);
    });

    test('リストは丸ごと 1 つの値（View の並び・z 順）', () {
      final c = <String>[];
      expect(m({'v': [1, 2]}, {'v': [2, 1]}, {'v': [1, 2, 3]}, c), {'v': [2, 1]});
      expect(c, ['v']);
    });
  });

  group('.qgs', () {
    String qgs(KMeta meta, {bool byQgis = false}) {
      final doc = QgsDocument.create(projectName: 'proj')..kokageMeta = jsonEncode(meta.toJson());
      doc.setStamp(KokageStamp(schemaVersion: 2, app: 'kokage-map', savedAt: DateTime(2026, 9, 29, 10), dirName: 'proj'));
      if (byQgis) doc.root.setAttribute('saveDateTime', '2026-09-29T11:00:00');
      return doc.toXmlString();
    }

    const link = KMetaSync(driveId: 'd', driveFolderName: 'proj');

    test('設定を合わせ、リンク情報はこの端末のもの', () async {
      final base = qgs(const KMeta(sync: link));
      final mine = qgs(const KMeta(
        sync: KMetaSync(driveId: 'd', driveFolderName: 'proj', isReadOnly: true),
        visibility: KMetaVisibility(geopackages: {'x.gpkg': false}),
      ));
      final theirs = qgs(const KMeta(
        sync: link,
        styles: KMetaStyles(layers: {'y.gpkg/y': KMetaLayerStyle(lineColor: Color(0xFFFF0000))}),
      ));
      final r = await QgsMerger.merge(base: base, mine: mine, theirs: theirs);
      expect(r, isNotNull);
      expect(r!.conflicts, isEmpty);
      final doc = QgsDocument.parse(r.xml);
      final meta = KMeta.fromJson(jsonDecode(doc.kokageMeta!) as Map<String, dynamic>);
      expect(meta.visibility.geopackages['x.gpkg'], isFalse);
      expect(meta.styles.layers['y.gpkg/y']!.lineColor, const Color(0xFFFF0000));
      expect(meta.sync.isReadOnly, isTrue);
      expect(doc.lastWrittenByKokage, isTrue);
    });

    test('QGIS で保存された側があれば合わせない（QGIS 側の変更が設定の JSON に入っていない）', () async {
      final base = qgs(const KMeta(sync: link));
      final r = await QgsMerger.merge(
        base: base,
        mine: qgs(const KMeta(sync: link, layout: KMetaLayout(expanded: true))),
        theirs: qgs(const KMeta(sync: link), byQgis: true),
      );
      expect(r, isNull);
    });
  });

  group('2 台の往復（偽の Drive）', () {
    late Directory tmp;
    late FakeGoogleDrive drive;
    late SyncEngine engine;
    late String rootId;
    late String a;
    late String b;
    final ledgers = <String, SyncLedgerEntry?>{};
    String? current;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('qgs_merge_rt_');
      drive = FakeGoogleDrive();
      engine = SyncEngine(driveService: drive);
      rootId = drive.createRootFolder('proj');
      // ローカルの dir 名は端末ごとに違う（`.qgs` は Drive のフォルダ名で共有される）
      a = (await Directory(p.join(tmp.path, '北山')).create()).path;
      b = p.join(tmp.path, '北山 (1)');
      KMetaService.instance.clearCache();
      SharedPreferences.setMockInitialValues({});
      ledgers.clear();
      current = null;
    });
    tearDown(() async {
      KMetaService.instance.clearCache();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));

    Future<void> asDevice(String dev) async {
      final key = SyncLedger.keyFor(driveId: rootId, folderPath: '');
      if (current != null) ledgers[current!] = await SyncLedger.instance.read(key);
      current = dev;
      final next = ledgers[dev];
      if (next != null) {
        await SyncLedger.instance.write(key, next);
      } else {
        await SyncLedger.instance.remove(key);
      }
      KMetaService.instance.clearCache();
    }

    Future<SyncResult> syncOnce(String local) async {
      await asDevice(local);
      final decisions = <MergeDecision>[];
      for (final e in await engine.getMergeEntries(local)) {
        if (e.isConflict) {
          expect(e.mergeable, isTrue, reason: '${e.relativePath} は base があるので合わせられるはず');
          decisions.add(MergeDecision(entry: e, choice: MergeChoice.merge));
        } else if (e.localChange != MergeChangeType.none) {
          decisions.add(MergeDecision(entry: e, choice: MergeChoice.local));
        } else if (e.remoteChange != MergeChangeType.none) {
          decisions.add(MergeDecision(entry: e, choice: MergeChoice.remote));
        }
      }
      final r = await engine.executeMerge(local, decisions);
      expect(r.success, isTrue, reason: r.errorMessage);
      return r;
    }

    Future<KMeta> metaOf(String dir) async {
      KMetaService.instance.clearCache();
      return KMetaService.instance.getMeta(dir);
    }

    test('2 台で別々に設定を変えても、両方の変更がそろう', () async {
      // A が作って上げ、B が落とす
      await asDevice(a);
      await KMetaService.instance.setGeoPackageVisibility(a, 'x.gpkg', false);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      expect(File(p.join(a, 'proj.qgs')).existsSync(), isTrue, reason: 'Drive のフォルダ名で書く');
      await asDevice(b);
      expect((await engine.pull(rootId, b)).success, isTrue);
      expect((await metaOf(b)).visibility.geopackages['x.gpkg'], isFalse);
      expect(Directory(b).listSync().map((e) => p.basename(e.path)), isNot(contains('北山 (1).qgs')));
      await tick();

      // それぞれ別のものを変える
      await asDevice(b);
      await KMetaService.instance.setLayerStyle(b, 'y.gpkg/y', const KMetaLayerStyle(lineColor: Color(0xFFFF0000)));
      await asDevice(a);
      await KMetaService.instance.setImageVisibility(a, 'IMG_1.jpg', false);
      await tick();

      final ra = await syncOnce(a); // A が先に上げる
      expect(ra.uploadedCount, 1);
      await tick();
      final rb = await syncOnce(b); // B は両方変わっている → 設定を合わせる
      expect(rb.mergedCount, 1);
      expect(rb.failedMerges, isEmpty);
      await tick();
      await syncOnce(a); // A は落とすだけ

      for (final dir in [a, b]) {
        final meta = await metaOf(dir);
        expect(meta.visibility.geopackages['x.gpkg'], isFalse, reason: dir);
        expect(meta.visibility.images['IMG_1.jpg'], isFalse, reason: dir);
        expect(meta.styles.layers['y.gpkg/y']?.lineColor, const Color(0xFFFF0000), reason: dir);
        expect(meta.sync.driveId, rootId, reason: '$dir のリンク情報は残る');
      }
      // どちらの端末にも `.qgs` は 1 本（名前の付け替え合いが起きない）
      for (final dir in [a, b]) {
        final names = Directory(dir).listSync().map((e) => p.basename(e.path)).where((n) => n.endsWith('.qgs'));
        expect(names, ['proj.qgs'], reason: dir);
      }
    });
  });
}
