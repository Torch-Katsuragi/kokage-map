// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [次のリリース],
  [次の版に入る直しです。],
  [],
)

#fixes(
  "直しました",
  [アプリが作るオーバーレイの GeoTIFF を QGIS と同じ GDAL で書くように。QGIS で開いても警告が出ない],
)
