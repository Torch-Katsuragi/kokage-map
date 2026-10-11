"""QGIS 本体に分類・段階・ルールのレンダラを書かせ、描き分けのテスト用 fixture を作り直す。

QGIS が地物ごとに選ぶシンボル（いちばん上に描かれるもの）も一緒に書き出す。アプリ側の評価が
QGIS と同じ色を選ぶかを、`test/qgis_renderer_test.dart` がこの答えと突き合わせる。

    & 'C:\\Program Files\\QGIS 4.2.2\\bin\\python-qgis.bat' tool/qgis/write_renderer_fixture.py

出力:
    test/fixtures/qgis_4_2_renderers.qgs            プロジェクト（データは .temp/qgs_renderers/ の gpkg）
    test/fixtures/qgis_4_2_renderers_expected.json  地物の属性と、QGIS が選んだシンボルの色
"""
import json
import os

from qgis.core import (
    QgsApplication, QgsProject, QgsVectorLayer, QgsFeature, QgsGeometry, QgsField, QgsFields,
    QgsVectorFileWriter, QgsCoordinateReferenceSystem, QgsCoordinateTransformContext, QgsWkbTypes,
    QgsFillSymbol, QgsLineSymbol, QgsMarkerSymbol, QgsRendererCategory, QgsCategorizedSymbolRenderer,
    QgsRendererRange, QgsGraduatedSymbolRenderer, QgsRuleBasedRenderer, QgsRenderContext,
    QgsExpressionContext, QgsExpressionContextUtils,
)
from qgis.PyQt.QtCore import QVariant, QMetaType

QgsApplication.setPrefixPath('', True)
app = QgsApplication([], False)
app.initQgis()

folder = os.path.abspath('.temp/qgs_renderers')
os.makedirs(folder, exist_ok=True)
gpkg = os.path.join(folder, '小班.gpkg')
if os.path.exists(gpkg):
    os.remove(gpkg)

ROWS = [
    # 樹種, 林齢, 面積
    ('スギ', 45, 1.2),
    ('スギ', 12, 0.4),
    ('ヒノキ', 30, 2.5),
    ('ヒノキ', 8, 0.9),
    ('マツ', 60, 3.1),
    ('広葉樹', 70, 5.0),
    (None, 25, 0.2),
    ('スギ', None, 1.0),
    ('その他', 100, 0.7),
    ('ヒノキ', 40, 1.5),
    ('スギ', 20, 0.3),
    ('針葉樹', 55, 0.8),
]


def write_layer(name, geom_type, make_geom):
    fields = QgsFields()
    fields.append(QgsField('樹種', QMetaType.Type.QString))
    fields.append(QgsField('林齢', QMetaType.Type.Int))
    fields.append(QgsField('面積', QMetaType.Type.Double))
    opts = QgsVectorFileWriter.SaveVectorOptions()
    opts.driverName = 'GPKG'
    opts.layerName = name
    opts.actionOnExistingFile = (QgsVectorFileWriter.CreateOrOverwriteLayer if os.path.exists(gpkg)
                                 else QgsVectorFileWriter.CreateOrOverwriteFile)
    writer = QgsVectorFileWriter.create(gpkg, fields, geom_type, QgsCoordinateReferenceSystem('EPSG:4326'),
                                        QgsCoordinateTransformContext(), opts)
    for i, (sp, age, area) in enumerate(ROWS):
        f = QgsFeature(fields)
        f.setAttributes([sp, age, area])
        f.setGeometry(make_geom(i))
        writer.addFeature(f)
    del writer


def square(i):
    x, y = 135.9 + (i % 4) * 0.01, 33.9 + (i // 4) * 0.01
    return QgsGeometry.fromWkt(f'POLYGON(({x} {y},{x + 0.009} {y},{x + 0.009} {y + 0.009},{x} {y + 0.009},{x} {y}))')


write_layer('shoban', QgsWkbTypes.Polygon, square)
write_layer('rindo', QgsWkbTypes.LineString,
            lambda i: QgsGeometry.fromWkt(f'LINESTRING({135.9 + i * 0.01} 33.8,{135.905 + i * 0.01} 33.81)'))
write_layer('kui', QgsWkbTypes.Point, lambda i: QgsGeometry.fromWkt(f'POINT({135.9 + i * 0.01} 33.7)'))

project = QgsProject.instance()
project.clear()
project.setTitle('描き分けの fixture')


def layer(table, name):
    lyr = QgsVectorLayer(f'{gpkg}|layername={table}', name, 'ogr')
    assert lyr.isValid(), name
    project.addMapLayer(lyr)
    return lyr


def fill(color, outline='35,35,35,255', width='0.26', style='solid', outline_style='solid'):
    return QgsFillSymbol.createSimple({'color': color, 'outline_color': outline, 'outline_width': width,
                                       'style': style, 'outline_style': outline_style})


# 1. 分類（樹種）。マツは描かない、それ以外の値は灰色
cat = layer('shoban', '樹種で分類')
cats = [
    QgsRendererCategory('スギ', fill('51,160,44,255'), 'スギ'),
    QgsRendererCategory('ヒノキ', fill('31,120,180,255', width='0.8'), 'ヒノキ'),
    QgsRendererCategory('マツ', fill('227,26,28,255'), 'マツ', False),
    QgsRendererCategory(None, fill('150,150,150,128'), 'その他'),
]
cat.setRenderer(QgsCategorizedSymbolRenderer('樹種', cats))

# 2. 段階（林齢）。範囲外（100 超え・NULL）は描かれない
grad = layer('shoban', '林齢で段階')
ranges = [
    QgsRendererRange(0, 20, fill('255,255,178,255'), '0 - 20'),
    QgsRendererRange(20, 40, fill('254,204,92,255'), '20 - 40'),
    QgsRendererRange(40, 60, fill('253,141,60,255', style='no'), '40 - 60'),
    QgsRendererRange(60, 80, fill('227,26,28,255', outline_style='no'), '60 - 80'),
]
grad.setRenderer(QgsGraduatedSymbolRenderer('"林齢"', ranges))

# 3. ルール
rule_layer = layer('shoban', 'ルールで')
root_rule = QgsRuleBasedRenderer.Rule(None)


def rule(parent, expr, color, label, else_rule=False, symbol=True):
    r = QgsRuleBasedRenderer.Rule(fill(color) if symbol else None, 0, 0, expr, label)
    if else_rule:
        r.setIsElse(True)
    parent.appendChild(r)
    return r


rule(root_rule, '"林齢" >= 40 AND "樹種" = \'スギ\'', '200,0,0,255', '高齢スギ')
hinoki = rule(root_rule, '"樹種" IN (\'ヒノキ\', \'マツ\')', '0,0,200,255', 'ヒノキ・マツ')
rule(hinoki, '"林齢" < 20', '255,255,0,255', '若い')
rule(root_rule, '"樹種" IS NULL', '128,128,128,255', '不明')
rule(root_rule, '"樹種" LIKE \'%葉%\' OR "面積" > 4.5', '0,128,0,255', '葉')
rule(root_rule, '', '255,255,255,255', 'その他', else_rule=True)
rule_layer.setRenderer(QgsRuleBasedRenderer(root_rule))

# 4. 線の分類（太さ違い・破線）
line = layer('rindo', '林道')
lines = [
    QgsRendererCategory('スギ', QgsLineSymbol.createSimple({'line_color': '255,0,0,255', 'line_width': '1.2'}), 'スギ'),
    QgsRendererCategory('ヒノキ', QgsLineSymbol.createSimple({'line_color': '0,0,255,255', 'line_width': '0.4',
                                                            'line_style': 'dash'}), 'ヒノキ'),
    QgsRendererCategory(None, QgsLineSymbol.createSimple({'line_color': '0,0,0,255', 'line_width': '0.26'}), ''),
]
line.setRenderer(QgsCategorizedSymbolRenderer('樹種', lines))

# 5. 点の段階（面積）。シンボルの不透明度つき
points = layer('kui', '杭')
small = QgsMarkerSymbol.createSimple({'name': 'circle', 'color': '0,128,255,255', 'size': '2'})
big = QgsMarkerSymbol.createSimple({'name': 'square', 'color': '255,128,0,255', 'size': '4'})
big.setOpacity(0.5)
points.setRenderer(QgsGraduatedSymbolRenderer('面積', [
    QgsRendererRange(0, 1, small, 'small'),
    QgsRendererRange(1, 10, big, 'big'),
]))

out = os.path.abspath('test/fixtures/qgis_4_2_renderers.qgs')
project.setFileName(out)
print('write() =', project.write())


def truth(lyr):
    ctx = QgsRenderContext()
    ctx.setExpressionContext(QgsExpressionContext(QgsExpressionContextUtils.globalProjectLayerScopes(lyr)))
    r = lyr.renderer().clone()
    r.startRender(ctx, lyr.fields())
    root_key = r.rootRule().ruleKey() if isinstance(r, QgsRuleBasedRenderer) else None
    rows = []
    for f in lyr.getFeatures():
        ctx.expressionContext().setFeature(f)
        syms = r.symbolsForFeature(f, ctx)
        top = syms[-1] if syms else None
        rows.append({
            'attrs': {'樹種': f['樹種'], '林齢': f['林齢'], '面積': f['面積']},
            'color': None if top is None else top.color().name(),
            'count': len(syms),
            # ルールは当たったルールの key（根を除く）。⚠ symbolsForFeature は ELSE を常に含めるので色は当てにならない
            'keys': sorted(k for k in r.legendKeysForFeature(f, ctx) if k != root_key),
        })
    r.stopRender(ctx)
    return rows


expected = {lyr.name(): truth(lyr) for lyr in (cat, grad, rule_layer, line, points)}
with open(os.path.abspath('test/fixtures/qgis_4_2_renderers_expected.json'), 'w', encoding='utf-8') as fp:
    json.dump(expected, fp, ensure_ascii=False, indent=1, default=lambda v: None)
print(json.dumps(expected, ensure_ascii=False)[:600])

app.exitQgis()
