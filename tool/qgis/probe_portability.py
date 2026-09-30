"""QGIS の携帯性まわりの挙動を確かめる（2026-09-30）。
E1 gpkg の既定スタイル（layer_styles）: 保存先と、素で追加したときの自動読込
E1b プロジェクトのスタイルと gpkg 既定スタイルのどちらが勝つか
E2 ファイル形式レイヤの既定スタイル（.qml 横置き）: 保存先と自動読込
E3 gpkg に名前付きスタイルを複数
E4 埋め込み: 親でスタイルを変えて保存 → 残るか / 親から地物編集できるか
E5 プロジェクトを gpkg の中に保存
E6 subsetString は既定スタイルに入るか
E7 未知の <properties><kokage> が QGIS の保存で残るか（QGIS 4 は <properties name="…"> の書き方なので
   この差し込みは空振りする。実ファイルでの確認は probe_portability2.py の E7）
E4 はツリーに足し忘れている。probe_portability2.py の E4 が正

使い方: "C:\\Program Files\\QGIS 4.2.2\\bin\\python-qgis.bat" probe_portability.py <作業dir>
"""
import os, shutil, sqlite3, sys, traceback
from qgis.core import (QgsApplication, QgsVectorLayer, QgsRasterLayer, QgsProject, QgsFeature,
                       QgsGeometry, QgsPointXY, QgsFields, QgsField, QgsVectorFileWriter,
                       QgsCoordinateReferenceSystem, QgsCoordinateTransformContext, QgsSymbol,
                       QgsSingleSymbolRenderer, QgsMapLayerStyle)
from qgis.core import Qgis, QgsMapLayer
from qgis.PyQt.QtCore import QMetaType
from qgis.PyQt.QtGui import QColor

W = sys.argv[1]
shutil.rmtree(W, ignore_errors=True)
os.makedirs(os.path.join(W, 'child'))
app = QgsApplication([], False)
app.initQgis()
print('QGIS', QgsApplication.instance().applicationVersion() if hasattr(QgsApplication, 'applicationVersion') else '')
from qgis.core import Qgis
print('version', Qgis.version())

def make_gpkg(path, layer='pts'):
    fields = QgsFields(); fields.append(QgsField('kind', QMetaType.Type.QString))
    opts = QgsVectorFileWriter.SaveVectorOptions(); opts.driverName = 'GPKG'; opts.layerName = layer
    w = QgsVectorFileWriter.create(path, fields, Qgis.WkbType.Point,QgsCoordinateReferenceSystem('EPSG:4326'),
                                   QgsCoordinateTransformContext(), opts)
    for i, k in enumerate(['a', 'b', 'a']):
        f = QgsFeature(fields); f.setAttribute('kind', k)
        f.setGeometry(QgsGeometry.fromPointXY(QgsPointXY(135.9 + i * 0.01, 33.7))); w.addFeature(f)
    del w

def color_of(layer):
    r = layer.renderer()
    return r.symbol().color().name() if isinstance(r, QgsSingleSymbolRenderer) else type(r).__name__

def recolor(layer, c):
    s = QgsSymbol.defaultSymbol(layer.geometryType()); s.setColor(QColor(c))
    layer.setRenderer(QgsSingleSymbolRenderer(s))

def run(name, fn):
    print(f'--- {name}')
    try: fn()
    except Exception: traceback.print_exc()

gp = os.path.join(W, 'child', 'data.gpkg'); make_gpkg(gp)
uri = gp + '|layername=pts'

def e1():
    l = QgsVectorLayer(uri, 'pts', 'ogr'); recolor(l, '#ff0000')
    print('saveDefaultStyle', l.saveDefaultStyle(QgsMapLayer.StyleCategory.AllStyleCategories) if False else l.saveDefaultStyle())
    print('qml sidecar exists', [f for f in os.listdir(os.path.dirname(gp)) if f.endswith('.qml')])
    con = sqlite3.connect(gp)
    print('tables', [r[0] for r in con.execute("select name from sqlite_master where type='table'")])
    try: print('layer_styles', list(con.execute('select f_table_name, styleName, useAsDefault from layer_styles')))
    except Exception as e: print('no layer_styles', e)
    con.close()
    l2 = QgsVectorLayer(uri, 'pts', 'ogr')  # 素で追加（loadDefaultStyle は既定で走る）
    print('fresh layer color', color_of(l2))
run('E1 gpkg default style', e1)

def e1b():
    p = QgsProject.instance(); p.clear()
    l = QgsVectorLayer(uri, 'pts', 'ogr'); recolor(l, '#00ff00'); p.addMapLayer(l)
    pp = os.path.join(W, 'e1b.qgs'); p.write(pp); p.clear()
    p.read(pp); l = list(p.mapLayers().values())[0]
    print('project style (green) vs gpkg default (red):', color_of(l))
    p.clear()
run('E1b project vs gpkg default', e1b)

def e2():
    gj = os.path.join(W, 'child', 'line.geojson')
    open(gj, 'w').write('{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[135.9,33.7],[135.95,33.72]]}}]}')
    l = QgsVectorLayer(gj, 'line', 'ogr'); recolor(l, '#0000ff')
    print('saveDefaultStyle', l.saveDefaultStyle())
    print('files', sorted(os.listdir(os.path.dirname(gj))))
    print('fresh layer color', color_of(QgsVectorLayer(gj, 'line', 'ogr')))
    # ラスタ
    tif = os.path.join(W, 'child', 'r.tif')
    from osgeo import gdal
    ds = gdal.GetDriverByName('GTiff').Create(tif, 4, 4, 1, gdal.GDT_Byte); ds.SetGeoTransform([135.9, .01, 0, 33.7, 0, -.01]); ds = None
    r = QgsRasterLayer(tif, 'r'); r.setOpacity(0.37)
    print('raster saveDefaultStyle', r.saveDefaultStyle())
    print('files', sorted(os.listdir(os.path.dirname(tif))))
    print('fresh raster opacity', QgsRasterLayer(tif, 'r').opacity())
run('E2 file-based default style', e2)

def e3():
    l = QgsVectorLayer(uri, 'pts', 'ogr')
    for name, c in [('緑', '#00aa00'), ('黄', '#dddd00')]:
        recolor(l, c)
        try: res = l.saveStyleToDatabaseV2(name, '', False, '')
        except AttributeError: res = l.saveStyleToDatabase(name, '', False, '')
        print('save', name, res)
    print('list', l.listStylesInDatabase())
    l2 = QgsVectorLayer(uri, 'pts', 'ogr'); print('fresh still default?', color_of(l2))
    sm = l2.styleManager(); print('styleManager styles', sm.styles())
run('E3 multiple named styles in gpkg', e3)

def e4():
    p = QgsProject.instance(); p.clear()
    l = QgsVectorLayer(uri, 'pts', 'ogr'); recolor(l, '#123456'); p.addMapLayer(l, False)
    g = p.layerTreeRoot().addGroup('child'); g.addLayer(l)
    cp = os.path.join(W, 'child', 'child.qgs'); p.write(cp); p.clear()
    ok = p.createEmbeddedGroup('child', cp, [])
    print('embedded group', ok is not None)
    pp = os.path.join(W, 'parent.qgs'); p.write(pp)
    l = list(p.mapLayers().values())[0]
    print('embedded color', color_of(l), 'isEditable', l.isEditable(), 'supportsEditing', l.supportsEditing())
    recolor(l, '#ff00ff'); p.write(pp); p.clear(); p.read(pp)
    l = list(p.mapLayers().values())[0]
    print('after restyle in parent + save + reload:', color_of(l))
    print('child.qgs untouched color?', '123456' in open(cp, encoding='utf-8').read().lower() or 'rgb check below')
    # 親から地物編集
    l.startEditing(); f = QgsFeature(l.fields()); f.setAttribute('kind', 'c')
    f.setGeometry(QgsGeometry.fromPointXY(QgsPointXY(136.0, 33.7))); l.addFeature(f); print('commit', l.commitChanges())
    print('feature count now', QgsVectorLayer(uri, 'x', 'ogr').featureCount())
    xml = open(pp, encoding='utf-8').read()
    i = xml.find('embedded'); print('parent xml around embedded:', xml[max(0, i - 200):i + 200].replace('\n', ' '))
    p.clear()
run('E4 embedded group', e4)

def e5():
    p = QgsProject.instance(); p.clear()
    p.addMapLayer(QgsVectorLayer(uri, 'pts', 'ogr'))
    target = f'geopackage:{gp}?projectName=proj1'
    print('write to gpkg', p.write(target)); p.clear()
    print('read back', p.read(target), len(p.mapLayers()))
    con = sqlite3.connect(gp); print('qgis_projects', [r[0] for r in con.execute('select name from qgis_projects')]); con.close()
    p.clear()
run('E5 project in gpkg', e5)

def e6():
    l = QgsVectorLayer(uri, 'pts', 'ogr'); l.setSubsetString("kind = 'a'"); recolor(l, '#abcdef')
    print('save default with subset', l.saveDefaultStyle())
    l2 = QgsVectorLayer(uri, 'pts', 'ogr'); print('fresh subset:', repr(l2.subsetString()), 'count', l2.featureCount(), color_of(l2))
    doc_has = 'kind' in (QgsMapLayerStyle() and '')
run('E6 subset in default style', e6)

def e7():
    p = QgsProject.instance(); p.clear()
    p.addMapLayer(QgsVectorLayer(uri, 'pts', 'ogr'))
    pp = os.path.join(W, 'e7.qgs'); p.write(pp); p.clear()
    xml = open(pp, encoding='utf-8').read()
    xml = xml.replace('<properties>', '<properties><kokage><meta type="QString">{"x":1}</meta><savedAt type="QString">t</savedAt></kokage>', 1)
    open(pp, 'w', encoding='utf-8').write(xml)
    p.read(pp); print('readEntry', p.readEntry('kokage', 'meta')); p.write(pp); p.clear()
    out = open(pp, encoding='utf-8').read(); i = out.find('<kokage'); print('after QGIS save:', out[i:i + 200].replace('\n', ' ') if i >= 0 else 'LOST')
run('E7 unknown kokage properties survive', e7)

from qgis.core import QgsMapLayer
app.exitQgis()
