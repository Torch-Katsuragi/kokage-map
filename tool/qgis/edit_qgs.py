"""QGIS 側で .qgs を編集して保存し直す（アプリの読み戻しの往復テスト用）。

    <QGIS>/bin/python-qgis.bat tool/qgis/edit_qgs.py <in.qgs> <out.qgs>

やること: 1 枚目の面レイヤに subset `area_ha > 5`、2 枚目のベクタを消灯、
ラスタがあれば不透明度 0.5 と改名。出力を `QgsDocument.apply()` / `QgsImporter` に食わせて
「QGIS の設定が残るか」「subset と消灯が読み戻せるか」を見る（2026-09-12 に QGIS 4.2.0 で確認）。
"""
import sys
from qgis.core import QgsApplication, QgsProject, QgsMapLayer

src, dst = sys.argv[1], sys.argv[2]
QgsApplication.setPrefixPath('', True)
app = QgsApplication([], False)
app.initQgis()

p = QgsProject.instance()
assert p.read(src), f'read failed: {src}'
vectors = [l for l in p.mapLayers().values() if l.type() == QgsMapLayer.VectorLayer]
rasters = [l for l in p.mapLayers().values() if l.type() == QgsMapLayer.RasterLayer]

if vectors:
    v0 = vectors[0]
    v0.setSubsetString('area_ha > 5')
    print(f'subset on {v0.name()!r}: {v0.subsetString()!r} -> features {v0.featureCount()}')
if len(vectors) > 1:
    v1 = vectors[1]
    p.layerTreeRoot().findLayer(v1.id()).setItemVisibilityChecked(False)
    print(f'unchecked {v1.name()!r}')
if rasters:
    r = rasters[0]
    r.renderer().setOpacity(0.5)
    r.setName('overlay renamed in QGIS')
    print(f'raster opacity 0.5 + renamed')

print('write:', p.write(dst))
app.exitQgis()
