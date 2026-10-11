"""QGIS 本体に「結合（Join）」を書かせ、森林簿 CSV と計画図の結合のテスト用 fixture を作り直す。

    & 'C:\\Program Files\\QGIS 4.2.2\\bin\\python-qgis.bat' tool/qgis/write_join_fixture.py

計画図（gpkg の小班ポリゴン）に 2 本の表を結合する:
    森林簿.csv       UTF-8。delimitedtext（QGIS の「CSV テキストレイヤを追加」）で読む。key = 林小班（文字）
                     樹種・林齢だけを結合し、接頭辞は既定（`森林簿_`）
    林班表.csv       Shift_JIS。ogr プロバイダ（ドラッグ&ドロップ）で読む。encoding=CP932。
                     計画図の rinpan（整数）と 林班（ogr の CSV なので文字列）を結ぶ。接頭辞は `林班_`

出力:
    test/fixtures/qgis_4_2_joins.qgs             プロジェクト（データは .temp/qgs_joins/）
    test/fixtures/qgis_4_2_joins_expected.json   QGIS が地物ごとに付けた結合の値
    test/fixtures/joins/森林簿.csv・林班表.csv    表（テストはこれと同じ形の gpkg をアプリで作って並べる）
"""
import json
import os
import shutil

from qgis.core import (
    QgsApplication, QgsProject, QgsVectorLayer, QgsFeature, QgsGeometry, QgsField, QgsFields,
    QgsVectorFileWriter, QgsCoordinateReferenceSystem, QgsCoordinateTransformContext, QgsWkbTypes,
    QgsVectorLayerJoinInfo,
)
from qgis.PyQt.QtCore import QMetaType

QgsApplication.setPrefixPath('', True)
app = QgsApplication([], False)
app.initQgis()

folder = os.path.abspath('.temp/qgs_joins')
if os.path.exists(folder):
    shutil.rmtree(folder)
os.makedirs(folder)
gpkg = os.path.join(folder, '計画図.gpkg')

# ---- 計画図（小班） ----
S = QMetaType.Type.QString
fields = QgsFields()
for name, kind in [('rinpan', QMetaType.Type.Int), ('shoban', S), ('key', S)]:
    fields.append(QgsField(name, kind))
opts = QgsVectorFileWriter.SaveVectorOptions()
opts.driverName = 'GPKG'
opts.layerName = 'shoban'
writer = QgsVectorFileWriter.create(gpkg, fields, QgsWkbTypes.Polygon, QgsCoordinateReferenceSystem('EPSG:4326'),
                                    QgsCoordinateTransformContext(), opts)
ROWS = [
    (12, '1', '12-1'),
    (12, '2', '12-2'),
    (13, '1', '13-1'),   # 森林簿に無い
    (14, '1', '14-1'),   # 林班表に無い
    (None, '9', None),   # 結合の値が NULL
]
for i, row in enumerate(ROWS):
    f = QgsFeature(fields)
    f.setAttributes(list(row))
    x = 135.9 + i * 0.01
    f.setGeometry(QgsGeometry.fromWkt(f'POLYGON(({x} 33.9,{x + 0.009} 33.9,{x + 0.009} 33.909,{x} 33.9))'))
    writer.addFeature(f)
del writer

# ---- 森林簿（UTF-8） ----
with open(os.path.join(folder, '森林簿.csv'), 'w', encoding='utf-8', newline='') as fp:
    fp.write('林小班,樹種,林齢,面積\r\n')
    fp.write('12-1,スギ,45,1.25\r\n')
    fp.write('12-2,"ヒノキ, 一部スギ",30,0.8\r\n')
    fp.write('14-1,広葉樹,60,2.5\r\n')

# ---- 林班表（Shift_JIS） ----
with open(os.path.join(folder, '林班表.csv'), 'w', encoding='cp932', newline='') as fp:
    fp.write('林班,所有者,地番\r\n')
    fp.write('12,北山村,①\r\n')
    fp.write('13,私有林,Ⅱ\r\n')

project = QgsProject.instance()
project.clear()
project.setTitle('結合の fixture')

shoban = QgsVectorLayer(f'{gpkg}|layername=shoban', 'shoban', 'ogr')
boki_uri = ('file:///' + os.path.join(folder, '森林簿.csv').replace('\\', '/') +
            '?type=csv&maxFields=10000&detectTypes=yes&geomType=none&subsetIndex=no&watchFile=no')
boki = QgsVectorLayer(boki_uri, '森林簿', 'delimitedtext')
rinpan = QgsVectorLayer(os.path.join(folder, '林班表.csv'), '林班表', 'ogr')
rinpan.setProviderEncoding('CP932')
for layer in (shoban, boki, rinpan):
    assert layer.isValid(), layer.name()
    project.addMapLayer(layer)

j1 = QgsVectorLayerJoinInfo()
j1.setJoinLayer(boki)
j1.setJoinFieldName('林小班')
j1.setTargetFieldName('key')
j1.setUsingMemoryCache(True)
j1.setJoinFieldNamesSubset(['樹種', '林齢'])
assert shoban.addJoin(j1)

j2 = QgsVectorLayerJoinInfo()
j2.setJoinLayer(rinpan)
j2.setJoinFieldName('林班')
j2.setTargetFieldName('rinpan')
j2.setUsingMemoryCache(True)
j2.setPrefix('林班_')
assert shoban.addJoin(j2)

expected = {
    'fields': [f.name() for f in shoban.fields()],
    'boki_types': {f.name(): f.typeName() for f in boki.fields()},
    'rinpan_types': {f.name(): f.typeName() for f in rinpan.fields()},
    'features': [],
}
for f in shoban.getFeatures():
    expected['features'].append({k: (None if v is None or (hasattr(v, 'isNull') and v.isNull()) else v)
                                 for k, v in zip(expected['fields'], f.attributes())})

out = os.path.abspath('test/fixtures/qgis_4_2_joins.qgs')
project.setFileName(os.path.join(folder, 'joins.qgs'))
print('write() =', project.write())
shutil.copyfile(os.path.join(folder, 'joins.qgs'), out)
os.makedirs(os.path.abspath('test/fixtures/joins'), exist_ok=True)
for name in ('森林簿.csv', '林班表.csv'):
    shutil.copyfile(os.path.join(folder, name), os.path.abspath(os.path.join('test/fixtures/joins', name)))
with open(os.path.abspath('test/fixtures/qgis_4_2_joins_expected.json'), 'w', encoding='utf-8') as fp:
    json.dump(expected, fp, ensure_ascii=False, indent=2, default=str)
print(json.dumps(expected, ensure_ascii=False, indent=2, default=str))

app.exitQgis()
