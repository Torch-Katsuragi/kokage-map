"""RootMap が書いた .qgs を QGIS 本体に開かせて確かめる。

    <QGIS>/bin/python-qgis-ltr.bat tool/qgis/check_qgs.py <project.qgs>
    （QGIS 4.x は python-qgis.bat）

レイヤが valid か、subset が効いているか、レンダラが読まれたかを出す。
終了コードは 0=OK / 1=NG。
"""
import sys
from qgis.core import QgsApplication, QgsProject, QgsRasterLayer, QgsVectorLayer

path = sys.argv[1]

QgsApplication.setPrefixPath('', True)
app = QgsApplication([], False)
app.initQgis()

project = QgsProject.instance()
ok = project.read(path)
print(f'read() = {ok}')
print(f'projectname = {project.title()!r}')

layers = project.mapLayers()
print(f'layers = {len(layers)}')

failed = 0
for lid, layer in layers.items():
    valid = layer.isValid()
    print(f'--- {layer.name()!r}')
    print(f'    id      = {lid}')
    print(f'    valid   = {valid}')
    print(f'    source  = {layer.source()}')
    if isinstance(layer, QgsVectorLayer):
        print(f'    subset  = {layer.subsetString()!r}')
        actual = sum(1 for _ in layer.getFeatures())
        print(f'    count   = {actual} (featureCount()={layer.featureCount()})')
        print(f'    crs     = {layer.crs().authid()}')
        renderer = layer.renderer()
        print(f'    renderer= {renderer.type() if renderer else None}')
        if renderer and renderer.type() == 'singleSymbol':
            sym = renderer.symbol()
            print(f'    symbol  = {sym.symbolLayer(0).layerType()} color={sym.color().name()}')
    if isinstance(layer, QgsRasterLayer):
        print(f'    crs     = {layer.crs().authid()}')
        print(f'    bands   = {layer.bandCount()} size={layer.width()}x{layer.height()}')
        print(f'    extent  = {layer.extent().toString(4)}')
    if not valid:
        failed += 1

# レイヤツリー（グループ構造）
def dump(node, depth=0):
    from qgis.core import QgsLayerTreeGroup, QgsLayerTreeLayer
    for child in node.children():
        if isinstance(child, QgsLayerTreeGroup):
            print('  ' * depth + f'[group] {child.name()}')
            dump(child, depth + 1)
        elif isinstance(child, QgsLayerTreeLayer):
            print('  ' * depth + f'[layer] {child.name()} checked={child.isVisible()}')

print('=== layer tree ===')
dump(project.layerTreeRoot())

app.exitQgis()
print(f'=== RESULT: {"OK" if ok and failed == 0 else "NG"} (invalid={failed}) ===')
sys.exit(0 if ok and failed == 0 else 1)
