// フォルダ設定の置き場を `.kmeta.json` から `<dir名>.qgs` の `kokage/meta` に移した（2026-09-29）。
// 設計は docs/technical/project-format-design.md の「正典を `.qgs` に移す」
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_meta_store.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/qgis/qgs_writer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late String dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('kmeta_qgs_');
    dir = (await Directory(p.join(tmp.path, 'Kitayama')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => dir);
  });
  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // 読み書きで失いやすいもの（写真の可視性・オーバーレイ・View・スタイル・並び・リンク）を全部持つ
  const rich = KMeta(
    visibility: KMetaVisibility(images: {'IMG_1.jpg': false}, folders: {'写真': false}),
    styles: KMetaStyles(
      layers: {'a.gpkg/trees': KMetaLayerStyle(polygonFillColor: Color(0xFF2E7D32), polygonBorderWidth: 2)},
    ),
    layout: KMetaLayout(sortOrder: ['b.gpkg', 'a.gpkg'], expanded: true),
    sync: KMetaSync(driveId: 'drive-1', driveFolderName: 'Kitayama', isReadOnly: true),
    views: {
      'a.gpkg/trees': [KMetaView(name: 'スギ', filter: "species = 'sugi'")],
    },
  );

  String qgsPath() => QgsProjectFile.pathFor(dir);
  String legacyPath() => p.join(dir, kMetaFileName);

  // QGIS 4.2 で保存し直すと `<kokage><meta>` が `<properties name="kokage"><properties name="meta">` になり、
  // saveDateTime も変わる（2026-09-30 に QGIS 4.2.2 で実測）。それでも設定が読め、書き足せること
  test('QGIS 4 で保存し直された `.qgs` からも設定を読み、書き足せる', () async {
    await QgsMetaStore.write(dir, rich);
    var xml = File(qgsPath()).readAsStringSync();
    xml = xml
        .replaceAllMapped(
          RegExp('<(kokage|schemaVersion|app|savedAt|savedBy|dirName|meta)( type="[^"]*")?>'),
          (m) => '<properties name="${m[1]}"${m[2] ?? ''}>',
        )
        .replaceAll(RegExp('</(kokage|schemaVersion|app|savedAt|savedBy|dirName|meta)>'), '</properties>')
        .replaceFirst(RegExp('saveDateTime="[^"]*"'), 'saveDateTime="2026-09-30T18:24:55"');
    expect(xml, isNot(contains('<kokage')));
    File(qgsPath()).writeAsStringSync(xml);
    KMetaService.instance.clearCache();

    expect(QgsDocument.parse(xml).lastWrittenByKokage, isFalse);
    expect(jsonEncode((await QgsMetaStore.read(dir))!.toJson()), jsonEncode(rich.toJson()));

    // QGIS が保存したファイルなので、印は付けず meta だけ書き換える。書き方も QGIS 4 のまま
    final changed = rich.copyWith(visibility: const KMetaVisibility(images: {'IMG_1.jpg': true}));
    expect(await QgsMetaStore.write(dir, changed), isTrue);
    final out = File(qgsPath()).readAsStringSync();
    expect(out, isNot(contains('<kokage')));
    expect('name="meta"'.allMatches(out), hasLength(1));
    expect(QgsDocument.parse(out).lastWrittenByKokage, isFalse);
    expect((await QgsMetaStore.read(dir))!.visibility.images['IMG_1.jpg'], isTrue);
  });

  test('書いたものがそのまま読める。`.kmeta.json` は作らない', () async {
    expect(await QgsMetaStore.write(dir, rich), isTrue);
    expect(File(qgsPath()).existsSync(), isTrue);
    expect(File(legacyPath()).existsSync(), isFalse);

    final read = await QgsMetaStore.read(dir);
    expect(jsonEncode(read!.toJson()), jsonEncode(rich.toJson()));
    // QGIS で開ける `.qgs` で、印も付いている
    final doc = QgsDocument.parse(File(qgsPath()).readAsStringSync());
    expect(doc.lastWrittenByKokage, isTrue);
    expect(doc.stamp!.dirName, 'Kitayama');
  });

  test('旧 `.kmeta.json` だけなら `.qgs` に移し、`.kmeta.json.migrated` に改名する', () async {
    File(legacyPath()).writeAsStringSync(jsonEncode(rich.toJson()));

    final read = await QgsMetaStore.read(dir);
    expect(jsonEncode(read!.toJson()), jsonEncode(rich.toJson()));
    expect(File(legacyPath()).existsSync(), isFalse);
    expect(File(p.join(dir, kMigratedMetaFileName)).existsSync(), isTrue);
    expect(QgsDocument.parse(File(qgsPath()).readAsStringSync()).kokageMeta, isNotNull);

    // 2 回目は `.qgs` から読む
    final again = await QgsMetaStore.read(dir);
    expect(jsonEncode(again!.toJson()), jsonEncode(rich.toJson()));
  });

  test('旧版（v1）の `.kmeta.json` も捨てずに移す（以前は sync 以外を捨てていた）', () async {
    final v1 = {...rich.toJson(), 'version': 1};
    File(legacyPath()).writeAsStringSync(jsonEncode(v1));
    final meta = await KMetaService.instance.getMeta(dir);
    expect(meta.views['a.gpkg/trees']!.single.name, 'スギ');
    expect(meta.visibility.images['IMG_1.jpg'], isFalse);
  });

  test('両方あれば `.qgs` が勝ち、`.kmeta.json` は退避する', () async {
    await QgsMetaStore.write(dir, rich);
    File(legacyPath()).writeAsStringSync(jsonEncode(const KMeta(layout: KMetaLayout(expanded: false)).toJson()));

    final read = await QgsMetaStore.read(dir);
    expect(read!.layout.expanded, isTrue);
    expect(File(legacyPath()).existsSync(), isFalse);
  });

  test('QGIS で作った `.qgs`（kokage/meta 無し）は空の設定。設定を持つ dir として扱う', () async {
    File(qgsPath()).writeAsStringSync(QgsDocument.create(projectName: 'Kitayama').toXmlString());
    expect(await QgsMetaStore.exists(dir), isTrue);
    final read = await QgsMetaStore.read(dir);
    expect(read, isNotNull);
    expect(read!.isEmpty, isTrue);
  });

  test('QGIS が後から保存した .qgs に設定を書いても、印は付けない（読み戻しが QGIS の変更を取り込めるように）', () async {
    await QgsMetaStore.write(dir, rich);
    // QGIS で保存した体: saveDateTime だけ進む（印の savedAt はそのまま）
    final saved = File(qgsPath()).readAsStringSync().replaceFirst(RegExp('saveDateTime="[^"]*"'), 'saveDateTime="2099-01-01T00:00:00"');
    File(qgsPath()).writeAsStringSync(saved);
    expect(QgsDocument.parse(saved).lastWrittenByKokage, isFalse);

    // 同じ設定なら書かない
    await QgsMetaStore.write(dir, rich);
    expect(File(qgsPath()).readAsStringSync(), saved);
    // 違う設定なら設定だけ書き、QGIS が保存したという印は残す
    await QgsMetaStore.write(dir, rich.copyWith(layout: const KMetaLayout(expanded: false)));
    final doc = QgsDocument.parse(File(qgsPath()).readAsStringSync());
    expect(doc.lastWrittenByKokage, isFalse);
    expect(doc.root.getAttribute('saveDateTime'), '2099-01-01T00:00:00');
    expect((await QgsMetaStore.read(dir))!.layout.expanded, isFalse);
  });

  test('書くときは直前の版を <名前>.qgs~ に残し、一時ファイルは残さない', () async {
    await QgsMetaStore.write(dir, rich);
    final first = File(qgsPath()).readAsStringSync();
    await QgsMetaStore.write(dir, rich.copyWith(layout: const KMetaLayout(expanded: false)));
    expect(File('${qgsPath()}~').readAsStringSync(), first);
    expect(File('${qgsPath()}.tmp').existsSync(), isFalse);
    expect((await QgsMetaStore.read(dir))!.layout.expanded, isFalse);
    // .qgs~ は設定の .qgs として拾わない
    expect(await QgsProjectFile.find(dir), qgsPath());
  });

  test('自動更新は、QGIS が後から保存した .qgs を読み戻すまで書かない（読み戻しが印を付け直したら書く）', () async {
    await KMetaService.instance.saveMeta(dir, rich);
    final root = FolderNode('Home', children: []);
    await const QgsProjectBuilder().writeTo(root);
    final qgisSaved = File(qgsPath()).readAsStringSync().replaceFirst(RegExp('saveDateTime="[^"]*"'), 'saveDateTime="2099-01-01T00:00:00"');
    File(qgsPath()).writeAsStringSync(qgisSaved);

    await const QgsProjectBuilder().writeTo(root);
    expect(File(qgsPath()).readAsStringSync(), qgisSaved, reason: '読み戻す前は触らない');

    await QgsMetaStore.claim(qgsPath());
    expect(QgsDocument.parse(File(qgsPath()).readAsStringSync()).lastWrittenByKokage, isTrue);
    await const QgsProjectBuilder().writeTo(root);
    expect(QgsDocument.parse(File(qgsPath()).readAsStringSync()).lastWrittenByKokage, isTrue);
  });

  test('何も無い dir は null（設定を持たない）', () async {
    expect(await QgsMetaStore.exists(dir), isFalse);
    expect(await QgsMetaStore.read(dir), isNull);
  });

  test('dir を改名しても、印を持つ `.qgs` を新しい名前に付け替えて引き継ぐ（連携していない dir）', () async {
    final local = rich.copyWith(sync: const KMetaSync());
    await QgsMetaStore.write(dir, local);
    final renamed = p.join(tmp.path, 'Kitayama-2027');
    await Directory(dir).rename(renamed);

    final read = await QgsMetaStore.read(renamed);
    expect(read!.views['a.gpkg/trees']!.single.name, 'スギ');
    expect(File(p.join(renamed, 'Kitayama-2027.qgs')).existsSync(), isTrue);
    expect(File(p.join(renamed, 'Kitayama.qgs')).existsSync(), isFalse);
  });

  test('Drive 連携している dir は `<Drive のフォルダ名>.qgs`。ローカルの dir 名が端末ごとに違っても同じ', () async {
    // この端末ではローカルの dir 名が「Kitayama」、Drive のフォルダ名は「北山 共有」
    const linked = KMeta(sync: KMetaSync(driveId: 'd', driveFolderName: '北山 共有'));
    await QgsMetaStore.write(dir, const KMeta());
    expect(File(p.join(dir, 'Kitayama.qgs')).existsSync(), isTrue);

    await QgsMetaStore.write(dir, linked); // 連携を始めた
    expect(File(p.join(dir, '北山 共有.qgs')).existsSync(), isTrue);
    expect(File(p.join(dir, 'Kitayama.qgs')).existsSync(), isFalse, reason: '二重にしない');
    final doc = QgsDocument.parse(File(p.join(dir, '北山 共有.qgs')).readAsStringSync());
    expect(doc.stamp!.dirName, '北山 共有', reason: '印とプロジェクト名も Drive の名前（端末ごとに書き換えない）');

    // 別の端末で「北山 (1)」という dir に落ちてきても、名前を付け替えずに読む
    final other = (await Directory(p.join(tmp.path, '北山 (1)')).create()).path;
    await File(p.join(dir, '北山 共有.qgs')).copy(p.join(other, '北山 共有.qgs'));
    final read = await QgsMetaStore.read(other);
    expect(read!.sync.driveId, 'd');
    expect(File(p.join(other, '北山 共有.qgs')).existsSync(), isTrue);
    expect(File(p.join(other, '北山 (1).qgs')).existsSync(), isFalse);

    // Drive のフォルダ名に使えない文字は置き換える
    expect(
      QgsProjectFile.projectNameFor(dir, const KMeta(sync: KMetaSync(driveId: 'd', driveFolderName: 'a/b:c'))),
      'a_b_c',
    );
  });

  test('印の無い別名の `.qgs`（他人のプロジェクト）は触らない', () async {
    final other = p.join(dir, 'mine.qgs');
    File(other).writeAsStringSync(QgsDocument.create(projectName: 'mine').toXmlString());
    expect(await QgsMetaStore.read(dir), isNull);
    expect(File(other).existsSync(), isTrue);
  });

  test('旧名 `project.qgs` は `<dir名>.qgs` に改名して引き継ぐ', () async {
    await QgsMetaStore.write(dir, rich);
    await File(qgsPath()).rename(p.join(dir, kLegacyQgsFileName));
    final read = await QgsMetaStore.read(dir);
    expect(read!.layout.sortOrder, ['b.gpkg', 'a.gpkg']);
    expect(File(qgsPath()).existsSync(), isTrue);
  });

  test('レイヤを書く自動更新（QgsProjectBuilder）はフォルダ設定を消さない', () async {
    await KMetaService.instance.saveMeta(dir, rich);
    final root = FolderNode('Home', children: []);
    await const QgsProjectBuilder().writeTo(root);
    KMetaService.instance.clearCache();
    final meta = await KMetaService.instance.getMeta(dir);
    expect(meta.views['a.gpkg/trees']!.single.filter, "species = 'sugi'");
  });

  test('設定の保存とレイヤの書き出しが同時でも、どちらも残る', () async {
    final root = FolderNode('Home', children: []);
    await Future.wait([
      for (var i = 0; i < 5; i++) ...[
        KMetaService.instance.setExpanded(dir, i.isEven),
        const QgsProjectBuilder().writeTo(root),
      ],
      KMetaService.instance.setImageVisibility(dir, 'IMG_9.jpg', false),
    ]);
    KMetaService.instance.clearCache();
    final meta = await KMetaService.instance.getMeta(dir);
    expect(meta.visibility.images['IMG_9.jpg'], isFalse);
    final doc = QgsDocument.parse(File(qgsPath()).readAsStringSync());
    expect(doc.kokageMeta, isNotNull);
    expect(doc.root.getElement('projectlayers'), isNotNull);
  });

  test('同期で `.qgs` を上書きしても、この端末のリンク情報（読み取り専用か）は残る', () async {
    await KMetaService.instance.saveMeta(dir, rich); // この端末: 読み取り専用
    final keep = await KMetaService.instance.linkBeforeReplace(qgsPath());
    expect(keep!.isReadOnly, isTrue);

    // Drive から落ちてきたもの: 持ち主の端末が書いた（読み取り専用ではない）、View が 1 枚増えている
    final remote = rich.copyWith(
      sync: const KMetaSync(driveId: 'drive-1', driveFolderName: 'Kitayama', isReadOnly: false),
      views: {
        'a.gpkg/trees': const [KMetaView(name: 'スギ'), KMetaView(name: 'ヒノキ')],
      },
    );
    final doc = QgsDocument.create(projectName: 'Kitayama')..kokageMeta = jsonEncode(remote.toJson());
    File(qgsPath()).writeAsStringSync(doc.toXmlString());

    await KMetaService.instance.afterReplace(qgsPath(), keep);
    KMetaService.instance.clearCache();
    final meta = await KMetaService.instance.getMeta(dir);
    expect(meta.sync.isReadOnly, isTrue); // この端末のまま
    expect(meta.views['a.gpkg/trees']!.length, 2); // 中身は Drive のもの
  });

  test('リンク情報が同じなら、上書き後に書き直さない（次の同期でまた上がらない）', () async {
    await KMetaService.instance.saveMeta(dir, rich);
    final keep = await KMetaService.instance.linkBeforeReplace(qgsPath());
    final before = File(qgsPath()).readAsStringSync();
    final t0 = File(qgsPath()).statSync().modified;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await KMetaService.instance.afterReplace(qgsPath(), keep);
    expect(File(qgsPath()).readAsStringSync(), before);
    expect(File(qgsPath()).statSync().modified, t0);
  });

  test('子 dir の `.qgs` は対象外（その dir の `<dir名>.qgs` 以外は触らない）', () async {
    expect(await KMetaService.instance.linkBeforeReplace(p.join(dir, 'other.qgs')), isNull);
    expect(await KMetaService.instance.linkBeforeReplace(p.join(dir, 'a.gpkg')), isNull);
  });
}
