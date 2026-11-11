"""QGIS 本体に .qgs を書かせ、インポータのテスト用 fixture を作り直す。

手で書いたXMLでは気づけない差（色の浮動小数表記、`<data_defined_properties>`）が
ここでしか出ないので、**QGISのバージョンを上げたら作り直すこと**。

    <QGIS>/bin/python-qgis-ltr.bat tool/qgis/write_fixture.py

⚠ `.temp/qgs_check/区画.gpkg` が要る。docs/technical/testing の
「最小のGeoPackageを標準ライブラリだけで作る」を参照。
"""
import os
from qgis.core import (
    QgsApplication, QgsProject, QgsVectorLayer, QgsLayerTreeGroup,
    QgsSingleSymbolRenderer, QgsMarkerSymbol,
)

QgsApplication.setPrefixPath('', True)
app = QgsApplication([], False)
app.initQgis()

folder = os.path.abspath('.temp/qgs_check')
gpkg = os.path.join(folder, '区画.gpkg')

project = QgsProject.instance()
project.clear()
project.setTitle('QGISが書いたプロジェクト')

root = project.layerTreeRoot()
group = root.addGroup('区画')

def add(name, subset, color, size):
    uri = f'{gpkg}|layername=parcels'
    if subset:
        uri += f'|subset={subset}'
    layer = QgsVectorLayer(uri, name, 'ogr')
    assert layer.isValid(), name
    symbol = QgsMarkerSymbol.createSimple({'name': 'circle', 'color': color, 'size': size})
    layer.setRenderer(QgsSingleSymbolRenderer(symbol))
    project.addMapLayer(layer, False)
    group.addLayer(layer)
    return layer

add('A種', "area > 105", '30,144,255,255', '4')
hidden = add('全部', None, '227,26,28,255', '2')
# 1枚は非表示にして、checked の読み取りも試せるようにする
root.findLayer(hidden.id()).setItemVisibilityChecked(False)

# 外部参照（root外）も1枚入れて、インポータが捨てられるか試せるようにする
outside = QgsVectorLayer(
    r'C:\work\dokoka.gpkg|layername=nowhere', 'root外', 'ogr'
)
project.addMapLayer(outside, False)
group.addLayer(outside)

out = os.path.abspath('test/fixtures/qgis_3_44_written.qgs')
project.setFileName(out)
ok = project.write()
print(f'write() = {ok} -> {out}')

app.exitQgis()
