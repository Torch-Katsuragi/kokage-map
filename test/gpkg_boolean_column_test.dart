// 真偽の列（宣言の型が BOOLEAN）に 1/0 の整数を書く。
//
// 実機（2026-10-12）: QGIS 4.2.2 で作った BOOLEAN の列「確認済」に QGIS のチェックボックス（CheckedState・UncheckedState が空 = 既定）
// を付けたレイヤを編集パネルで直すと、横に「true」と出て、gpkg には文字の 'true' が入っていた。
// GDAL・QGIS は BOOLEAN の列の文字を 0（外れ）と読むので、付けたチェックが QGIS で消えていた。
// QGIS（QgsCheckboxWidgetWrapper）は bool の列では設定の値を見ずに真偽を書き、GDAL が 0/1 にする
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/qgis_form.dart';
import 'package:root_maps/services/qgis_form_logic.dart';
import 'package:root_maps/utils/attribute_columns.dart';
import 'package:root_maps/widgets/qgis_form/qgis_field_input.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/gdal_host.dart';
import 'support/gdal_scenarios.dart';

/// QGIS 4.2.2 が BOOLEAN の列に付けたチェックボックスの設定（既定のまま）
const _qgisDefault = QgisFieldForm(
  name: '確認済',
  widgetType: 'CheckBox',
  config: {'CheckedState': '', 'UncheckedState': ''},
);

const _yesNo = QgisFieldForm(
  name: 'bassai',
  widgetType: 'CheckBox',
  config: {'CheckedState': 'Y', 'UncheckedState': 'N'},
);

void main() {
  LocaleSettings.setLocaleSync(AppLocale.ja);

  group('真偽として読む', () {
    test('1/0・true/false・t/f・yes/no と bool。空・読めない値は null', () {
      for (final v in [1, 1.0, true, 'true', 'TRUE', 't', 'T', '1', 'yes', 'y', ' true ']) {
        expect(parseBooleanValue(v), isTrue, reason: '$v');
      }
      for (final v in [0, 0.0, false, 'false', 'False', 'f', '0', 'no', 'n']) {
        expect(parseBooleanValue(v), isFalse, reason: '$v');
      }
      for (final v in [null, '', '  ', 'abc']) {
        expect(parseBooleanValue(v), isNull, reason: '$v');
      }
    });

    test('書く形は 1/0。空は NULL、読めない値はそのまま', () {
      expect(toBooleanStorage('true'), 1);
      expect(toBooleanStorage(false), 0);
      expect(toBooleanStorage('f'), 0);
      expect(toBooleanStorage(''), isNull);
      expect(toBooleanStorage(null), isNull);
      expect(toBooleanStorage('abc'), 'abc');
      expect(normalizeAttributeInput('BOOLEAN', 'true'), 1);
      expect(normalizeAttributeInput('boolean', 't'), 1);
      expect(normalizeAttributeInput('TEXT', 'true'), 'true');
    });
  });

  group('チェックボックスの値（QgsCheckboxWidgetWrapper に合わせる）', () {
    test('BOOLEAN の列は設定によらず 1/0', () {
      expect(qgisCheckValues(_qgisDefault, 'BOOLEAN'), (1, 0));
      expect(qgisCheckValues(_yesNo, 'BOOLEAN'), (1, 0), reason: 'QGIS は bool の列で CheckedState を見ない');
      expect(qgisCheckValues(null, 'BOOLEAN'), (1, 0));
    });

    test('ほかの列は設定の値を文字のまま。設定が空なら数の列は 1/0、文字の列は true/false', () {
      expect(qgisCheckValues(_yesNo, 'TEXT'), ('Y', 'N'));
      expect(qgisCheckValues(_yesNo, 'INTEGER'), ('Y', 'N'));
      expect(qgisCheckValues(_qgisDefault, 'INTEGER'), (1, 0));
      expect(qgisCheckValues(_qgisDefault, 'TEXT'), ('true', 'false'));
    });

    test('状態を読む', () {
      for (final v in [1, 'true', 't', '1', true]) {
        expect(qgisCheckState(_qgisDefault, 'BOOLEAN', v), isTrue, reason: '$v');
      }
      for (final v in [0, 'false', 'f', '0', false]) {
        expect(qgisCheckState(_qgisDefault, 'BOOLEAN', v), isFalse, reason: '$v');
      }
      expect(qgisCheckState(_qgisDefault, 'BOOLEAN', null), isNull);
      expect(qgisCheckState(_yesNo, 'BOOLEAN', 1), isTrue, reason: 'BOOLEAN では設定の値を見ない');
      expect(qgisCheckState(_yesNo, 'TEXT', 'Y'), isTrue);
      expect(qgisCheckState(_yesNo, 'TEXT', 'N'), isFalse);
      expect(qgisCheckState(_yesNo, 'TEXT', 'true'), isFalse, reason: 'CheckedState と違えば外れ（QGIS と同じ）');
      expect(qgisCheckState(_yesNo, 'TEXT', ''), isNull);
      expect(qgisCheckState(_qgisDefault, 'TEXT', 'true'), isTrue);
      expect(qgisCheckState(_qgisDefault, 'INTEGER', 0), isFalse);
    });
  });

  group('欄', () {
    Future<List<(Object?, bool)>> pump(WidgetTester tester, QgisFieldForm? field, Object? value,
        {String sqlType = 'BOOLEAN'}) async {
      final changes = <(Object?, bool)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QgisFieldInput(
            column: '確認済',
            field: field,
            sqlType: sqlType,
            value: value,
            onChanged: (v, {required commit}) => changes.add((v, commit)),
          ),
        ),
      ));
      return changes;
    }

    testWidgets('QGIS 既定のチェックボックス（BOOLEAN）: 付けると整数 1、外すと 0。横に値の文字を出さない', (tester) async {
      var changes = await pump(tester, _qgisDefault, 0);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(find.text('false'), findsNothing);
      expect(find.text('0'), findsNothing);
      await tester.tap(find.byType(Checkbox));
      expect(changes.last, (1, true));

      changes = await pump(tester, _qgisDefault, 1);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      expect(find.text('true'), findsNothing);
      expect(find.text('1'), findsNothing);
      await tester.tap(find.byType(Checkbox));
      expect(changes.last, (0, true));
    });

    testWidgets('以前の版が書いた文字の true も付いていると読み、書き直すと 0/1', (tester) async {
      final changes = await pump(tester, _qgisDefault, 'true');
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      await tester.tap(find.byType(Checkbox));
      expect(changes.last, (0, true));
    });

    testWidgets('NULL: 外れで出して（なし）と添える。AllowNullState なら三つめの状態', (tester) async {
      await pump(tester, _qgisDefault, null);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(find.text(t.qgisForm.noValue), findsOneWidget);

      const tri = QgisFieldForm(name: '確認済', widgetType: 'CheckBox', config: {'AllowNullState': true});
      await pump(tester, tri, null);
      final box = tester.widget<Checkbox>(find.byType(Checkbox));
      expect((box.tristate, box.value), (true, null));
      expect(find.text(t.qgisForm.noValue), findsNothing);
    });

    testWidgets('設定の無い BOOLEAN の列もチェックボックス（1/0 を書く）', (tester) async {
      final changes = await pump(tester, null, null);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byType(Checkbox));
      expect(changes.last, (1, true));
    });

    testWidgets('設定のある文字の列は CheckedState を文字で書く', (tester) async {
      final changes = await pump(tester, _yesNo, 'N', sqlType: 'TEXT');
      await tester.tap(find.byType(Checkbox));
      expect(changes.last, ('Y', true));
      expect(find.text('Y'), findsNothing);
    });
  });

  group('gpkg に書く', () {
    const table = 'chosa';
    late Directory tmp;
    late String path;
    late GeoPackageFile gpkg;

    final gdalConfig = findHostGdal();
    GdalFfi? gdal;

    setUpAll(() async {
      // GDAL を先に読む（sqflite が先に別の sqlite3.dll を読むと、QGIS の gdal*.dll が読めない）
      if (gdalConfig != null) {
        gdal = GdalFfi(gdalConfig);
        await gdal!.version();
      }
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gpkg_bool_');
      path = p.join(tmp.path, 'b.gpkg');
      gpkg = GeoPackageFile(const ['b.gpkg'], absolutePath: path);
      await gpkg.addLayer(table, GeometryType.point);
      await gpkg.addAttributeColumns(table, {'name': 'TEXT', '確認済': 'BOOLEAN', '伐採': 'BOOLEAN', 'memo': 'TEXT'});
      await gpkg.addPointWithAttributes(table, const LatLng(33.93, 135.96), {'name': 'a', '確認済': 'true'});
      await gpkg.addPointWithAttributes(table, const LatLng(33.94, 135.97), {'name': 'b'});
      await gpkg.flushChanges();
    });

    tearDown(() async {
      await gpkg.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    /// こかげマップと別の接続で読んだ値と SQLite の型
    Future<List<(Object?, String)>> onDisk(String column) async {
      final db = await openDatabase(path, singleInstance: false, readOnly: true);
      final rows = await db.rawQuery('SELECT "$column" AS v, typeof("$column") AS t FROM $table ORDER BY fid');
      await db.close();
      return [for (final r in rows) (r['v'], r['t']! as String)];
    }

    test('足すとき・1 列直すとき・まとめて直すとき、BOOLEAN の列は整数 1/0。文字の列はそのまま', () async {
      expect((await onDisk('確認済')).first, (1, 'integer'), reason: '足した行');

      expect(await gpkg.updateFeatureAttribute(table, 1, '確認済', 'false'), isTrue);
      expect((await onDisk('確認済')).first, (0, 'integer'));

      expect(await gpkg.updateFeatureAttributes(table, 2, {'確認済': true, 'memo': 'true'}), isTrue);
      expect((await onDisk('確認済'))[1], (1, 'integer'));
      expect((await onDisk('memo'))[1], ('true', 'text'));

      expect(await gpkg.updateFeatureAttributes(table, 2, {'確認済': ''}), isTrue);
      expect((await onDisk('確認済'))[1], (null, 'null'));
    });

    test('以前の版が書いた文字の真偽は、その行を書くときに 1/0 に直す（開いただけでは書き換えない）', () async {
      final db = await openDatabase(path, singleInstance: false);
      await db.execute("UPDATE $table SET 伐採 = 'true' WHERE fid = 1");
      await db.execute("UPDATE $table SET 伐採 = 'false' WHERE fid = 2");
      await db.close();

      expect(await gpkg.updateFeatureAttributes(table, 1, {'name': 'a2'}), isTrue);
      expect(await onDisk('伐採'), [(1, 'integer'), ('false', 'text')], reason: '書いた行だけ直す');
    });

    test('GDAL が真偽として読める（QGIS で付けたチェックが残る）', () async {
      await gpkg.updateFeatureAttributes(table, 2, {'確認済': 'false'});
      await gpkg.flushChanges();
      final info = await gdal!.vectorInfo(path, args: const ['-features']);
      expect(featureValues(info, '確認済'), [true, false]);
    }, skip: gdalConfig == null ? 'GDAL が見つからない（QGIS か libgdal-dev を入れる）' : null);
  });
}
