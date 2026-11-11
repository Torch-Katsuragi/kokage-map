"""QGIS 本体に「結合（Join）」を書かせ、台帳 CSV と計画図の結合のテスト用 fixture を作り直す。

    & 'C:\\Program Files\\QGIS 4.2.2\\bin\\python-qgis.bat' tool/qgis/write_join_fixture.py

計画図（gpkg の区画ポリゴン）に 2 本の表を結合する:
    台帳.csv         UTF-8。delimitedtext（QGIS の「CSV テキストレイヤを追加」）で読む。key = 区画番号（文字）
                     区分・年数だけを結合し、接頭辞は既定（`台帳_`）
    地区表.csv       Shift_JIS。ogr プロバイダ（ドラッグ&ドロップ）で読む。encoding=CP932。
                     計画図の block（整数）と 地区（ogr の CSV なので文字列）を結ぶ。接頭辞は `地区_`

出力:
    test/fixtures/qgis_4_2_joins.qgs             プロジェクト（データは .temp/qgs_joins/）
    test/fixtures/qgis_4_2_joins_expected.json   QGIS が地物ごとに付けた結合の値
    test/fixtures/joins/台帳.csv・地区表.csv      表（テストはこれと同じ形の gpkg をアプリで作って並べる）
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

# ---- 計画図（区画） ----
S = QMetaType.Type.QString
fields = QgsFields()
for name, kind in [('block', QMetaType.Type.Int), ('parcel', S), ('key', S)]:
    fields.append(QgsField(name, kind))
opts = QgsVectorFileWriter.SaveVectorOptions()
opts.driverName = 'GPKG'
opts.layerName = 'parcels'
writer = QgsVectorFileWriter.create(gpkg, fields, QgsWkbTypes.Polygon, QgsCoordinateReferenceSystem('EPSG:4326'),
                                    QgsCoordinateTransformContext(), opts)
ROWS = [
    (12, '1', '12-1'),
    (12, '2', '12-2'),
    (13, '1', '13-1'),   # 台帳に無い
    (14, '1', '14-1'),   # 地区表に無い
    (None, '9', None),   # 結合の値が NULL
]
for i, row in enumerate(ROWS):
    f = QgsFeature(fields)
    f.setAttributes(list(row))
    x = 135.9 + i * 0.01
    f.setGeometry(QgsGeometry.fromWkt(f'POLYGON(({x} 33.9,{x + 0.009} 33.9,{x + 0.009} 33.909,{x} 33.9))'))
    writer.addFeature(f)
del writer

# ---- 台帳（UTF-8） ----
with open(os.path.join(folder, '台帳.csv'), 'w', encoding='utf-8', newline='') as fp:
    fp.write('区画番号,区分,年数,面積\r\n')
    fp.write('12-1,種別A,45,1.25\r\n')
    fp.write('12-2,"種別B, 一部A",30,0.8\r\n')
    fp.write('14-1,種別C,60,2.5\r\n')

# ---- 地区表（Shift_JIS） ----
with open(os.path.join(folder, '地区表.csv'), 'w', encoding='cp932', newline='') as fp:
    fp.write('地区,所有者,地番\r\n')
    fp.write('12,山間市,①\r\n')
    fp.write('13,民有地,Ⅱ\r\n')

project = QgsProject.instance()
project.clear()
project.setTitle('結合の fixture')

parcels = QgsVectorLayer(f'{gpkg}|layername=parcels', 'parcels', 'ogr')
ledger_uri = ('file:///' + os.path.join(folder, '台帳.csv').replace('\\', '/') +
              '?type=csv&maxFields=10000&detectTypes=yes&geomType=none&subsetIndex=no&watchFile=no')
ledger = QgsVectorLayer(ledger_uri, '台帳', 'delimitedtext')
block_table = QgsVectorLayer(os.path.join(folder, '地区表.csv'), '地区表', 'ogr')
block_table.setProviderEncoding('CP932')
for layer in (parcels, ledger, block_table):
    assert layer.isValid(), layer.name()
    project.addMapLayer(layer)

j1 = QgsVectorLayerJoinInfo()
j1.setJoinLayer(ledger)
j1.setJoinFieldName('区画番号')
j1.setTargetFieldName('key')
j1.setUsingMemoryCache(True)
j1.setJoinFieldNamesSubset(['区分', '年数'])
assert parcels.addJoin(j1)

j2 = QgsVectorLayerJoinInfo()
j2.setJoinLayer(block_table)
j2.setJoinFieldName('地区')
j2.setTargetFieldName('block')
j2.setUsingMemoryCache(True)
j2.setPrefix('地区_')
assert parcels.addJoin(j2)

expected = {
    'fields': [f.name() for f in parcels.fields()],
    'ledger_types': {f.name(): f.typeName() for f in ledger.fields()},
    'block_types': {f.name(): f.typeName() for f in block_table.fields()},
    'features': [],
}
for f in parcels.getFeatures():
    expected['features'].append({k: (None if v is None or (hasattr(v, 'isNull') and v.isNull()) else v)
                                 for k, v in zip(expected['fields'], f.attributes())})

out = os.path.abspath('test/fixtures/qgis_4_2_joins.qgs')
project.setFileName(os.path.join(folder, 'joins.qgs'))
print('write() =', project.write())
shutil.copyfile(os.path.join(folder, 'joins.qgs'), out)
os.makedirs(os.path.abspath('test/fixtures/joins'), exist_ok=True)
for name in ('台帳.csv', '地区表.csv'):
    shutil.copyfile(os.path.join(folder, name), os.path.abspath(os.path.join('test/fixtures/joins', name)))
with open(os.path.abspath('test/fixtures/qgis_4_2_joins_expected.json'), 'w', encoding='utf-8') as fp:
    json.dump(expected, fp, ensure_ascii=False, indent=2, default=str)
print(json.dumps(expected, ensure_ascii=False, indent=2, default=str))

app.exitQgis()
