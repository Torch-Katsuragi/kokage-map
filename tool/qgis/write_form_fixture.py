"""QGIS 本体に属性フォームの設定（編集ウィジェット・別名・既定値・制約・読み取り専用・ドラッグ&ドロップの配置）を
書かせ、属性フォームのテスト用 fixture を作り直す。

    & 'C:\\Program Files\\QGIS 4.2.2\\bin\\python-qgis.bat' tool/qgis/write_form_fixture.py

出力:
    test/fixtures/qgis_4_2_forms.qgs   プロジェクト（データは .temp/qgs_forms/ の gpkg）
"""
import os

from qgis.core import (
    Qgis, QgsApplication, QgsProject, QgsVectorLayer, QgsFeature, QgsGeometry, QgsField, QgsFields,
    QgsVectorFileWriter, QgsCoordinateReferenceSystem, QgsCoordinateTransformContext, QgsWkbTypes,
    QgsEditorWidgetSetup, QgsDefaultValue, QgsFieldConstraints, QgsAttributeEditorContainer,
    QgsAttributeEditorField,
)
from qgis.PyQt.QtCore import QMetaType

QgsApplication.setPrefixPath('', True)
app = QgsApplication([], False)
app.initQgis()

folder = os.path.abspath('.temp/qgs_forms')
os.makedirs(folder, exist_ok=True)
gpkg = os.path.join(folder, '調査.gpkg')
if os.path.exists(gpkg):
    os.remove(gpkg)


def write_layer(name, geom_type, field_defs, rows, make_geom):
    fields = QgsFields()
    for fname, ftype in field_defs:
        fields.append(QgsField(fname, ftype))
    opts = QgsVectorFileWriter.SaveVectorOptions()
    opts.driverName = 'GPKG'
    opts.layerName = name
    opts.actionOnExistingFile = (QgsVectorFileWriter.CreateOrOverwriteLayer if os.path.exists(gpkg)
                                 else QgsVectorFileWriter.CreateOrOverwriteFile)
    writer = QgsVectorFileWriter.create(gpkg, fields, geom_type, QgsCoordinateReferenceSystem('EPSG:4326'),
                                        QgsCoordinateTransformContext(), opts)
    for i, row in enumerate(rows):
        f = QgsFeature(fields)
        f.setAttributes(list(row))
        f.setGeometry(make_geom(i))
        writer.addFeature(f)
    del writer


S = QMetaType.Type.QString
write_layer('parcels', QgsWkbTypes.Polygon, [('code', S), ('name', S), ('block', QMetaType.Type.Int)], [
    ('1-a', '1区 い号', 1),
    ('1-b', '1区 ろ号', 1),
    ('2-a', '2区 い号', 2),
], lambda i: QgsGeometry.fromWkt(
    f'POLYGON(({135.9 + i * 0.01} 33.9,{135.909 + i * 0.01} 33.9,{135.909 + i * 0.01} 33.909,{135.9 + i * 0.01} 33.9))'))

CHOSA_FIELDS = [
    ('kind', S),           # ValueMap
    ('done', S),           # CheckBox
    ('chosabi', QMetaType.Type.QDate),  # DateTime
    ('width', QMetaType.Type.Double),   # Range（数の欄）
    ('age', QMetaType.Type.Int),        # Range（つまみ）
    ('memo', S),           # TextEdit（複数行）
    ('chosasha', S),       # UniqueValues
    ('uid', S),            # Hidden + 既定値 uuid() + 一意
    ('kiroku', QMetaType.Type.QDateTime),  # 既定値 now()
    ('koshin', S),         # 既定値 $now（更新時も）
    ('kubun', S),          # 既定値 'A'
    ('parcels', S),        # ValueRelation
    ('biko', S),           # 読み取り専用
    ('iro', S),            # Color（未対応の部品 → 文字の欄）
    ('fukusu', S),         # 未対応の既定値の式
]
write_layer('chosa', QgsWkbTypes.Point, CHOSA_FIELDS, [
    ('SG', 'Y', '2026-05-01', 32.5, 45, '', '佐藤', '{a}', None, None, 'A', '1-a', '', '', ''),
    ('HN', 'N', '2026-05-02', 18.0, 20, '', '山田', '{b}', None, None, 'B', '2-a', '', '', ''),
], lambda i: QgsGeometry.fromWkt(f'POINT({135.9 + i * 0.01} 33.7)'))

project = QgsProject.instance()
project.clear()
project.setTitle('属性フォームの fixture')

parcels = QgsVectorLayer(f'{gpkg}|layername=parcels', 'parcels', 'ogr')
chosa = QgsVectorLayer(f'{gpkg}|layername=chosa', 'chosa', 'ogr')
assert parcels.isValid() and chosa.isValid()
project.addMapLayer(parcels)
project.addMapLayer(chosa)


def idx(name):
    return chosa.fields().indexOf(name)


def widget(name, kind, config):
    chosa.setEditorWidgetSetup(idx(name), QgsEditorWidgetSetup(kind, config))


widget('kind', 'ValueMap', {'map': [{'種別A': 'SG'}, {'種別B': 'HN'}, {'種別C': 'KO'}]})
widget('done', 'CheckBox', {'CheckedState': 'Y', 'UncheckedState': 'N', 'TextDisplayMethod': 0})
widget('chosabi', 'DateTime', {'field_format': 'yyyy-MM-dd', 'display_format': 'yyyy/MM/dd',
                               'calendar_popup': True, 'allow_null': True})
widget('width', 'Range', {'Min': 0.0, 'Max': 200.0, 'Step': 0.5, 'Style': 'SpinBox', 'Precision': 1,
                          'AllowNull': True})
widget('age', 'Range', {'Min': 0, 'Max': 150, 'Step': 5, 'Style': 'Slider', 'AllowNull': True})
widget('memo', 'TextEdit', {'IsMultiline': True, 'UseHtml': False})
widget('chosasha', 'UniqueValues', {'Editable': True})
widget('uid', 'Hidden', {})
widget('parcels', 'ValueRelation', {
    'Layer': parcels.id(), 'LayerName': 'parcels', 'LayerSource': parcels.source(), 'LayerProviderName': 'ogr',
    'Key': 'code', 'Value': 'name', 'FilterExpression': '"block" = 1', 'AllowNull': True,
    'OrderByValue': True, 'AllowMulti': False,
})
widget('iro', 'Color', {})

chosa.setFieldAlias(idx('kind'), '種別')
chosa.setFieldAlias(idx('done'), '完了済み')
chosa.setFieldAlias(idx('chosabi'), '調査日')
chosa.setFieldAlias(idx('width'), '幅員(m)')
chosa.setFieldAlias(idx('age'), '年数')
chosa.setFieldAlias(idx('memo'), 'メモ')

chosa.setDefaultValueDefinition(idx('uid'), QgsDefaultValue('uuid()'))
chosa.setDefaultValueDefinition(idx('kiroku'), QgsDefaultValue('now()'))
chosa.setDefaultValueDefinition(idx('koshin'), QgsDefaultValue('$now', True))
chosa.setDefaultValueDefinition(idx('kubun'), QgsDefaultValue("'A'"))
chosa.setDefaultValueDefinition(idx('fukusu'), QgsDefaultValue('@user_full_name'))

C = QgsFieldConstraints
chosa.setFieldConstraint(idx('kind'), C.ConstraintNotNull, C.ConstraintStrengthHard)
chosa.setFieldConstraint(idx('uid'), C.ConstraintUnique, C.ConstraintStrengthHard)
chosa.setConstraintExpression(idx('width'), '"width" > 0 AND "width" < 150', '幅員は 0〜150 m')
chosa.setFieldConstraint(idx('width'), C.ConstraintExpression, C.ConstraintStrengthSoft)
chosa.setFieldConstraint(idx('chosasha'), C.ConstraintNotNull, C.ConstraintStrengthSoft)

cfg = chosa.editFormConfig()
cfg.setReadOnly(idx('biko'), True)
cfg.setLayout(Qgis.AttributeFormLayout.DragAndDrop)
cfg.clearTabs()
root = cfg.invisibleRootContainer()


def container(name, parent, kind):
    c = QgsAttributeEditorContainer(name, parent)
    c.setType(kind)
    return c


def add_fields(c, names):
    for n in names:
        c.addChildElement(QgsAttributeEditorField(n, idx(n), c))


kihon = container('基本', root, Qgis.AttributeEditorContainerType.Tab)
add_fields(kihon, ['kind', 'width', 'age', 'done'])
shosai = container('詳細', kihon, Qgis.AttributeEditorContainerType.GroupBox)
add_fields(shosai, ['chosabi', 'chosasha'])
kihon.addChildElement(shosai)
cfg.addTab(kihon)
sonota = container('その他', root, Qgis.AttributeEditorContainerType.Tab)
add_fields(sonota, ['memo', 'parcels', 'biko', 'kubun', 'iro'])
cfg.addTab(sonota)
chosa.setEditFormConfig(cfg)

out = os.path.abspath('test/fixtures/qgis_4_2_forms.qgs')
project.setFileName(out)
print('write() =', project.write())

app.exitQgis()
