import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/settings_schema.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/qgis_symbol.dart';
import 'package:root_maps/screens/layer_style_settings/kmeta_style_sync.dart';
import 'package:root_maps/screens/layer_style_settings/style_templates.dart';
import 'package:root_maps/screens/layer_style_settings/symbol_style_defs.dart';
import 'package:root_maps/services/qgis/qgs_qml_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

SettingsStore _makeStore() => createLayerStyleSettingsStore(
      labelExpressionTileDef: CustomDef(
        key: 'test_label_expr',
        title: 'label',
        builder: (_, _, _) => const SizedBox.shrink(),
      ),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LocaleSettings.setLocaleSync(AppLocale.ja);
  });

  test('点・線・面の全 19 テンプレートが一意な ID と ja/en ラベルを持ち、SettingsStore 上で排他的に一致判定できる', () async {
    final store = _makeStore();
    await store.load();
    store.loadOverlay(null);

    final allIds = <String>{};
    for (final geom in GeometryType.values) {
      final list = styleTemplatesFor(geom);
      expect(list.length, greaterThanOrEqualTo(6));
      for (final tpl in list) {
        expect(allIds.add(tpl.id), isTrue, reason: 'ID 重複: ${tpl.id}');
        LocaleSettings.setLocaleSync(AppLocale.ja);
        expect(tpl.label.trim(), isNotEmpty);
        LocaleSettings.setLocaleSync(AppLocale.en);
        expect(tpl.label.trim(), isNotEmpty);

        await tpl.applyToStore(store);
        final matched = [for (final other in list) if (other.matchesStore(store)) other.id];
        expect(matched, [tpl.id], reason: '${tpl.id} 適用時は自分自身だけ一致すべき');
      }
    }
  });

  test('全 19 テンプレートが KMetaLayerStyle → QML 書き出し → QML 読み込みで形状・縁取り・破線・ハッチングを往復保持する', () async {
    final store = _makeStore();
    await store.load();

    for (final geom in GeometryType.values) {
      for (final tpl in styleTemplatesFor(geom)) {
        store.loadOverlay(null);
        await tpl.applyToStore(store);

        final kmeta = buildStyleFromStore(
          store,
          omitLayerQgisRenderer: false,
          qgisRenderer: null,
          qgisRendererDef: null,
        );
        final xml = QgsQmlService.exportQml(style: kmeta, geometryType: geom);
        final imported = QgsQmlService.importQml(xml, expectedGeometryType: geom);
        expect(imported, isA<QmlImportSuccess>(), reason: tpl.id);
        final roundTripped = (imported as QmlImportSuccess).style;

        final checkStore = _makeStore();
        await checkStore.load();
        checkStore.loadOverlay(roundTripped);

        switch (tpl) {
          case final PointStyleTemplate p:
            expect(PointMarkerShape.fromId(checkStore.getString(pointShapeDef)), p.shape, reason: tpl.id);
            expect(checkStore.getColor(pointColorDef).toARGB32(), p.color.toARGB32(), reason: tpl.id);
            expect(checkStore.getBool(pointOutlineEnabledDef), p.outlineEnabled, reason: tpl.id);
          case final LineStyleTemplate l:
            expect(LineDashPattern.fromId(checkStore.getString(lineDashDef)), l.dash, reason: tpl.id);
            expect(checkStore.getColor(lineColorDef).toARGB32(), l.color.toARGB32(), reason: tpl.id);
            expect(checkStore.getBool(lineCasingEnabledDef), l.casingEnabled, reason: tpl.id);
            if (l.casingEnabled) {
              expect(checkStore.getColor(lineCasingColorDef).toARGB32(), l.casingColor.toARGB32(), reason: tpl.id);
            }
          case final PolygonStyleTemplate g:
            expect(
              PolygonFillPattern.fromId(checkStore.getString(polygonFillPatternDef)),
              g.fillPattern,
              reason: tpl.id,
            );
            expect(
              LineDashPattern.fromId(checkStore.getString(polygonBorderDashDef)),
              g.borderDash,
              reason: tpl.id,
            );
            expect(checkStore.getBool(polygonBorderCasingEnabledDef), g.borderCasingEnabled, reason: tpl.id);
            if (g.borderCasingEnabled) {
              expect(
                checkStore.getColor(polygonBorderCasingColorDef).toARGB32(),
                g.borderCasingColor.toARGB32(),
                reason: tpl.id,
              );
            }
        }
      }
    }
  });

  testWidgets('StyleTemplateSection: チップをタップするとテンプレートが適用されて選択状態が切り替わる', (tester) async {
    final store = _makeStore();
    await store.load();
    store.loadOverlay(null);

    StyleTemplate? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: StyleTemplateSection(
                geometryType: GeometryType.polygon,
                store: store,
                hasCustomSymbolLayers: false,
                onSelect: (tpl) async {
                  selected = tpl;
                  await tpl.applyToStore(store);
                  setState(() {});
                },
              ),
            ),
          ),
        ),
      ),
    );

    final target = polygonStyleTemplates.firstWhere((t) => t.id == 'poly_cross_hazard');
    final chipFinder = find.byKey(ValueKey('style_template_${target.id}'));
    expect(chipFinder, findsOneWidget);

    await tester.tap(chipFinder);
    await tester.pumpAndSettle();

    expect(selected?.id, 'poly_cross_hazard');
    expect(store.getString(polygonFillPatternDef), 'cross');
    expect(store.getBool(polygonBorderCasingEnabledDef), isTrue);
    expect(target.matchesStore(store), isTrue);
  });
}
