"""probe.py の続き。E4 埋め込みのやり直し、E7 アプリが書いた .qgs を QGIS 4.2 で開いて保存、
E8 gpkg の既定スタイルの保存先（データソース側）と、.qml と DB スタイルの優先順、1 gpkg 複数レイヤでの .qml

使い方: "C:\\Program Files\\QGIS 4.2.2\\bin\\python-qgis.bat" probe_portability2.py <作業dir>
（E7 用に、こかげマップが書いた dir を <作業dir>/real に置いておく）"""
import os, shutil, sqlite3, sys, traceback
from qgis.core import (Qgis, QgsApplication, QgsVectorLayer, QgsProject, QgsFeature, QgsGeometry, QgsPointXY,
                       QgsFields, QgsField, QgsVectorFileWriter, QgsCoordinateReferenceSystem,
                       QgsCoordinateTransformContext, QgsSymbol, QgsSingleSymbolRenderer, QgsMapLayer)
from qgis.PyQt.QtCore import QMetaType
from qgis.PyQt.QtGui import QColor

B = sys.argv[1]; W = os.path.join(B, 'work2')
shutil.rmtree(W, ignore_errors=True); os.makedirs(os.path.join(W, 'child'))
app = QgsApplication([], False); app.initQgis()

def make_gpkg(path, layer, mode=QgsVectorFileWriter.ActionOnExistingFile.CreateOrOverwriteFile):
    fields = QgsFields(); fields.append(QgsField('kind', QMetaType.Type.QString))
    o = QgsVectorFileWriter.SaveVectorOptions(); o.driverName = 'GPKG'; o.layerName = layer; o.actionOnExistingFile = mode
    w = QgsVectorFileWriter.create(path, fields, Qgis.WkbType.Point, QgsCoordinateReferenceSystem('EPSG:4326'),
                                   QgsCoordinateTransformContext(), o)
    for i, k in enumerate(['a', 'b', 'a']):
        f = QgsFeature(fields); f.setAttribute('kind', k)
        f.setGeometry(QgsGeometry.fromPointXY(QgsPointXY(135.9 + i * .01, 33.7))); w.addFeature(f)
    del w

def color_of(l):
    r = l.renderer(); return r.symbol().color().name() if isinstance(r, QgsSingleSymbolRenderer) else type(r).__name__
def recolor(l, c):
    s = QgsSymbol.defaultSymbol(l.geometryType()); s.setColor(QColor(c)); l.setRenderer(QgsSingleSymbolRenderer(s))
def run(n, fn):
    print('---', n)
    try: fn()
    except Exception: traceback.print_exc()

gp = os.path.join(W, 'child', 'data.gpkg'); make_gpkg(gp, 'pts')
make_gpkg(gp, 'pts2', QgsVectorFileWriter.ActionOnExistingFile.CreateOrOverwriteLayer)
u1, u2 = gp + '|layername=pts', gp + '|layername=pts2'

def e4():
    p = QgsProject.instance(); p.clear()
    l = QgsVectorLayer(u1, 'pts', 'ogr'); recolor(l, '#123456'); p.addMapLayer(l, False)
    p.layerTreeRoot().addGroup('child').addLayer(l)
    cp = os.path.join(W, 'child', 'child.qgs'); p.write(cp); p.clear()
    g = p.createEmbeddedGroup('child', cp, []); p.layerTreeRoot().addChildNode(g)
    pp = os.path.join(W, 'parent.qgs'); p.write(pp)
    l = list(p.mapLayers().values())[0]
    print('embedded color', color_of(l))
    recolor(l, '#ff00ff'); p.write(pp); p.clear(); p.read(pp)
    l = list(p.mapLayers().values())[0]
    print('restyled in parent → saved → reloaded:', color_of(l))
    print('startEditing', l.startEditing())
    f = QgsFeature(l.fields()); f.setAttribute('kind', 'c'); f.setGeometry(QgsGeometry.fromPointXY(QgsPointXY(136, 33.7)))
    l.addFeature(f); print('commit', l.commitChanges(), 'count', QgsVectorLayer(u1, 'x', 'ogr').featureCount())
    x = open(pp, encoding='utf-8').read(); i = x.find('embedded')
    print('parent xml:', x[max(0, i - 150):i + 250].replace('\n', ' '))
    # 子を直す → 親に反映されるか
    p.clear(); p.read(cp); l = list(p.mapLayers().values())[0]; recolor(l, '#00ffff'); p.write(cp); p.clear()
    p.read(pp); print('child restyled → parent sees:', color_of(list(p.mapLayers().values())[0])); p.clear()
run('E4 embedded group', e4)

def e7():
    src = os.path.join(B, 'real'); dst = os.path.join(W, 'real'); shutil.copytree(src, dst)
    q = [f for f in os.listdir(dst) if f.endswith('.qgs')][0]; pp = os.path.join(dst, q)
    before = open(pp, encoding='utf-8').read()
    p = QgsProject.instance(); p.clear(); print('read', p.read(pp), 'layers', len(p.mapLayers()))
    print('readEntry meta', p.readEntry('kokage', 'meta')[0][:60], '| savedAt', p.readEntry('kokage', 'savedAt'))
    l = [x for x in p.mapLayers().values()][0]; recolor(l, '#ff8800')  # QGIS 側で色を変えて保存
    print('write', p.write(pp)); p.clear()
    after = open(pp, encoding='utf-8').read(); i = after.find('kokage')
    print('after:', after[max(0, i - 80):i + 400].replace('\n', ' '))
    import re
    m0 = re.search(r'"version":2.*?(?=</meta>|")', before); print('meta same?', ('"version":2' in after), before.count('geodiff試験.gpkg/trees'), after.count('geodiff試験.gpkg/trees'))
    print('root attrs:', re.search(r'<qgis [^>]*>', after).group(0))
run('E7 app-written .qgs through QGIS 4.2 save', e7)

def e8():
    # .qml 横置き: 1 gpkg に 2 レイヤ
    l1 = QgsVectorLayer(u1, 'pts', 'ogr'); recolor(l1, '#aa0000'); print('pts qml', l1.saveDefaultStyle(QgsMapLayer.StyleCategory.AllStyleCategories))
    l2 = QgsVectorLayer(u2, 'pts2', 'ogr'); recolor(l2, '#00aa00'); print('pts2 qml', l2.saveDefaultStyle(QgsMapLayer.StyleCategory.AllStyleCategories))
    print('files', sorted(os.listdir(os.path.dirname(gp))))
    print('fresh pts', color_of(QgsVectorLayer(u1, 'a', 'ogr')), 'fresh pts2', color_of(QgsVectorLayer(u2, 'b', 'ogr')))
    # DB に既定として保存
    l1 = QgsVectorLayer(u1, 'pts', 'ogr'); recolor(l1, '#0000aa')
    print('db default', l1.saveStyleToDatabaseV2('既定', '', True, ''))
    con = sqlite3.connect(gp); print(list(con.execute('select f_table_name, styleName, useAsDefault from layer_styles'))); con.close()
    print('fresh pts (db default vs qml)', color_of(QgsVectorLayer(u1, 'a', 'ogr')))
    print('fresh pts2 (qml only)', color_of(QgsVectorLayer(u2, 'b', 'ogr')))
    # gpkg を別の場所へコピー（.qml は置いていかない）→ DB スタイルはついてくる
    cp = os.path.join(W, 'moved.gpkg'); shutil.copy(gp, cp)
    print('moved gpkg pts', color_of(QgsVectorLayer(cp + '|layername=pts', 'a', 'ogr')), 'pts2', color_of(QgsVectorLayer(cp + '|layername=pts2', 'b', 'ogr')))
run('E8 default style storage & priority', e8)
app.exitQgis()
