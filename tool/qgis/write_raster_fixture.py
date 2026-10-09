"""QGIS 本体に「ラスタと XYZ タイルを足したプロジェクト」を書かせ、読み戻しのテスト用 fixture を作る。

QGIS のユーザーがプロジェクト dir に GeoTIFF を置いて足した・背景に地理院タイルを敷いた、の体。
手で書いた XML では `<pipe>` の形（不透明度の置き場所）や XYZ の URI の符号化を外しやすいので本体に書かせる。

    & 'C:\\Program Files\\QGIS 4.2.2\\bin\\python-qgis.bat' tool/qgis/write_raster_fixture.py

出力は `test/fixtures/qgis_4_2_raster_xyz.qgs`。参照は `.temp/qgs_raster/proj/` からの相対パスで入る
（テストは同じ名前のファイルを一時 dir に作ってから読む）。
"""
import os
from urllib.parse import quote

from osgeo import gdal, osr
from qgis.core import QgsApplication, QgsProject, QgsRasterLayer

QgsApplication.setPrefixPath('', True)
app = QgsApplication([], False)
app.initQgis()

base = os.path.abspath('.temp/qgs_raster')
proj = os.path.join(base, 'proj')
outside = os.path.join(base, 'outside')
os.makedirs(proj, exist_ok=True)
os.makedirs(outside, exist_ok=True)


def geotiff(path):
    """4326 の小さな GeoTIFF（北山村あたり）"""
    ds = gdal.GetDriverByName('GTiff').Create(path, 40, 30, 3, gdal.GDT_Byte)
    ds.SetGeoTransform([135.97, 0.0001, 0, 33.94, 0, -0.0001])
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(4326)
    ds.SetProjection(srs.ExportToWkt())
    for b in range(1, 4):
        ds.GetRasterBand(b).Fill(80 * b)
    ds = None


geotiff(os.path.join(proj, 'ortho.tif'))
geotiff(os.path.join(proj, 'hidden.tif'))
geotiff(os.path.join(outside, 'kyoyu.tif'))
gdal.Translate(os.path.join(proj, 'scan.png'), os.path.join(proj, 'ortho.tif'), format='PNG')

project = QgsProject.instance()
project.clear()
project.setTitle('ラスタと背景地図')
root = project.layerTreeRoot()


def add(layer, opacity=None, checked=True):
    assert layer.isValid() or layer.providerType() == 'wms', layer.name()
    if opacity is not None:
        layer.renderer().setOpacity(opacity)
    project.addMapLayer(layer, False)
    node = root.addLayer(layer)
    node.setItemVisibilityChecked(checked)
    return layer


def xyz(name, url, zmax=18):
    uri = f'type=xyz&url={quote(url, safe="")}&zmax={zmax}&zmin=0'
    return QgsRasterLayer(uri, name, 'wms')


add(QgsRasterLayer(os.path.join(proj, 'ortho.tif'), 'オルソ', 'gdal'), opacity=0.5)
add(QgsRasterLayer(os.path.join(proj, 'hidden.tif'), 'hidden', 'gdal'), checked=False)
add(QgsRasterLayer(os.path.join(proj, 'scan.png'), 'スキャン', 'gdal'))
add(QgsRasterLayer(os.path.join(outside, 'kyoyu.tif'), '共有オルソ', 'gdal'))
add(xyz('地理院 淡色', 'https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png'), opacity=0.6, checked=False)
add(xyz('どこかのタイル', 'https://tiles.example.com/v1/{z}/{x}/{y}.png'))
# 本物の WMS（オフラインでは invalid になるが、書かれる形は同じ）
wms = QgsRasterLayer(
    'contextualWMSLegend=0&crs=EPSG:4326&dpiMode=7&format=image/png&layers=foo&styles&'
    'url=https://wms.example.com/wms',
    '何かの WMS',
    'wms',
)
project.addMapLayer(wms, False)
root.addLayer(wms)

out = os.path.abspath('test/fixtures/qgis_4_2_raster_xyz.qgs')
# 参照を proj からの相対にするため、いったん proj に書いてから移す
tmp = os.path.join(proj, 'proj.qgs')
project.setFileName(tmp)
ok = project.write()
with open(tmp, encoding='utf-8') as f:
    xml = f.read()
with open(out, 'w', encoding='utf-8', newline='\n') as f:
    f.write(xml)
print(f'write() = {ok} -> {out}')

app.exitQgis()
