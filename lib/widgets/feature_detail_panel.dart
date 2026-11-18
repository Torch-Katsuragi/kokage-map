// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// フィーチャ詳細パネルウィジェット

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../editing/edit_session.dart';
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/gnss_quality.dart';
import '../models/nodes/current_location_node.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/image_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/nodes/official_layer_node.dart';
import '../models/nodes/overlay_image_node.dart';
import '../models/qgis_form.dart';
import '../presentation/attribute_display.dart';
import '../presentation/feature_display_name.dart';
import '../providers/notification_providers.dart';
import '../providers/project_providers.dart';
import '../providers/selection_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/qgis_form_options.dart';
import '../services/survey/traverse_recorder.dart';
import '../tutorial/tutorial.dart';
import '../utils/geodesic.dart';
import '../widgets/info_panel_card.dart';
import '../widgets/long_press_delete_button.dart';
import '../widgets/photo_viewer.dart';
import 'external_layer_actions.dart';

class FeatureDetailPanel extends ConsumerWidget {
  final dynamic feature;
  final void Function(LayerTreeNode target)? onOpenInTree;
  const FeatureDetailPanel({super.key, required this.feature, this.onOpenInTree});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (feature == null) return const SizedBox.shrink();

    // 現在位置（擬似フィーチャ）
    if (feature is CurrentLocationNode) {
      return _buildCurrentLocation(context, ref, feature as CurrentLocationNode);
    }

    if (feature is OfficialFeatureNode) {
      return _OfficialFeatureCard(
        node: feature as OfficialFeatureNode,
        onOpenInTree: onOpenInTree,
        googleMapsButton: _googleMapsButton,
      );
    }

    // OverlayImageNode用の詳細パネル（ImageNodeより先にチェック）
    if (feature is OverlayImageNode) {
      final overlay = feature as OverlayImageNode;
      final params = overlay.overlayParams;

      return _buildPanel(
        context,
        ref,
        title: '🗺️ オーバーレイ画像',
        children: [
          // オーバーレイアイコン
          Container(
            width: double.infinity,
            height: 60,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.teal.shade200),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.layers, color: Colors.teal.shade400, size: 24),
                const SizedBox(height: 4),
                Text(
                  'GeoTIFF',
                  style: TextStyle(
                    color: Colors.teal.shade600,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          // 名前
          _labelRow(t.featureDetail.nameLabel, overlay.name),
          const SizedBox(height: 4),
          // 中心座標
          _labelRow(
            t.featureDetail.coordLabel,
            '${params.centerLat.toStringAsFixed(6)}, ${params.centerLng.toStringAsFixed(6)}',
            style: _small,
          ),
          const SizedBox(height: 4),
          // スケール・回転
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.featureDetail.scaleLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('${params.scale.toStringAsFixed(3)} m/px', style: const TextStyle(fontSize: 11)),
              const SizedBox(width: 12),
              Text(t.featureDetail.rotationLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('${params.rotation.toStringAsFixed(1)}°', style: const TextStyle(fontSize: 11)),
            ],
          ),
          const SizedBox(height: 4),
          // 画像サイズ
          _labelRow(
            t.featureDetail.sizeLabel,
            '${params.imageWidth} x ${params.imageHeight}',
            style: _small,
          ),
          // 削除ボタン
          const SizedBox(height: 12),
          if (onOpenInTree != null) ...[
            _openInTreeButton(feature as LayerTreeNode),
            const SizedBox(height: 8),
          ],
          _deleteButton(ref),
        ],
      );
    }

    // ImageNode用の詳細パネル
    if (feature is ImageNode) {
      final photo = feature as ImageNode;

      // プロジェクトルートからの相対パスを計算
      final projectRoot = ref.read(projectRootDirProvider);
      String displayPath = photo.filePath;
      if (projectRoot != null && photo.filePath.startsWith(projectRoot)) {
        displayPath = photo.filePath.substring(projectRoot.length);
        if (displayPath.startsWith('\\') || displayPath.startsWith('/')) {
          displayPath = displayPath.substring(1);
        }
      }

      return _buildPanel(
        context,
        ref,
        title: '📸 写真ファイル',
        // 写真は背景に薄く敷く（[FeatureSilhouette]）。大きく見るのは見出しの右のボタンで
        action: IconButton.filledTonal(
          key: TutorialTargets.photoPreview,
          iconSize: 28,
          tooltip: t.featureDetail.viewPhoto,
          icon: const Icon(Icons.zoom_in),
          onPressed: () {
            ref.read(tutorialProvider.notifier).report(const PhotoViewed());
            showPhotoViewer(context, imagePath: photo.filePath);
          },
        ),
        children: [
          // 詳細情報
          _labelRow(t.featureDetail.nameLabel, photo.name),
          const SizedBox(height: 4),
          _labelRow(t.featureDetail.pathLabel, displayPath, style: _small),
          const SizedBox(height: 4),
          _labelRow(
            t.featureDetail.coordLabel,
            photo.hasLocation
                ? '${photo.location!.latitude.toStringAsFixed(6)}, ${photo.location!.longitude.toStringAsFixed(6)}'
                : t.featureDetail.noLocation,
            style: TextStyle(
              fontSize: 11,
              color: photo.hasLocation ? null : Colors.grey,
              fontStyle: photo.hasLocation ? null : FontStyle.italic,
            ),
          ),
          if (photo.takenAt != null) ...[
            const SizedBox(height: 4),
            _labelRow(t.featureDetail.dateLabel, '${photo.takenAt}', style: _small),
          ],
          const SizedBox(height: 4),
          _labelRow(
            t.featureDetail.sizeLabel,
            '${(photo.metadata.fileSize / (1024 * 1024)).toStringAsFixed(1)} MB',
            style: _small,
          ),
          // 位置がある写真は点と同じく Google Maps のリンク（長押しで開く）
          if (photo.hasLocation) ...[
            const SizedBox(height: 12),
            _googleMapsButton(ref, photo.location!.latitude, photo.location!.longitude),
          ],
          // 削除ボタン
          const SizedBox(height: 12),
          if (onOpenInTree != null) ...[
            _openInTreeButton(feature as LayerTreeNode),
            const SizedBox(height: 8),
          ],
          _deleteButton(ref),
        ],
      );
    }

    // 既存のFeatureNode用の処理
    if (feature is FeatureNode) {
      final node = feature as FeatureNode; // dynamic のフィールドは is で昇格しない
      final infoMap = node.infoMap;
      // 形の列（名前は表ごと）は属性に入っていない。geom という名前のふつうの列は出す
      // メタデータの列は infoMap に入っていない（以前は名前に metadata を含む列をすべて隠していた）
      const hiddenKeys = {'sub_table'};
      final filteredEntries =
          infoMap.entries
              .where((entry) =>
                  !hiddenKeys.contains(entry.key))
              .toList();

      // 長さ・面積・周長（WGS84 楕円体の上で測る。投影座標系のレイヤも読み込み時に WGS84 へ直してある）
      // 続けて計算した情報（座標・頂点数・記録の時間）。属性とは別に出す（同名の列の値を隠さない）
      final measures = <(String, String)>[
        if (node is LineFeatureNode) (t.featureDetail.lengthLabel, Geodesic.formatLength(node.length)),
        if (node is PolygonFeatureNode) ...[
          (t.featureDetail.areaLabel, Geodesic.formatArea(node.area)),
          (t.featureDetail.perimeterLabel, Geodesic.formatLength(node.perimeter)),
        ],
        ...node.computedInfo,
        if (node is PointFeatureNode)
          if (TraverseRecorder.backsightDeltaOf(node) case final d?)
            (
              '${t.trupulse.backsightCorrected}: ',
              t.trupulse.backsightDiff(
                azDelta: d.azDeg.toStringAsFixed(1),
                hdDelta: d.hdM.toStringAsFixed(2),
              ),
            ),
      ];

      final children = <Widget>[
        // QGIS の表示名（式が列 1 つだけならその列の行で足りるので出さない）
        if (featureQgisDisplayName(node) case final display?)
          Padding(
            padding: const EdgeInsets.only(bottom: 4.0),
            child: _labelRow(t.featureDetail.displayNameLabel, display),
          ),
        for (final (label, value) in measures)
          Padding(
            padding: const EdgeInsets.only(bottom: 4.0),
            child: _labelRow(label, value),
          ),
        if (measures.isNotEmpty) const SizedBox(height: 4),
        if (filteredEntries.isNotEmpty) _AttributeRows(node: node, entries: filteredEntries),
        // GPS 測量の品質（kmaps_metadata の測量の記録から）
        if (summarizeFeatureQuality(node.metadata, isPoint: node is PointFeatureNode)
            case final quality?)
          Padding(
            padding: const EdgeInsets.only(bottom: 4.0),
            child: _labelRow('${t.gnssQuality.label}: ', quality),
          ),
      ];

      // Point は Google Maps のリンクをコピー（長押しで開く。開くのは隠し機能扱い）
      if (feature is PointFeatureNode) {
        final point = (feature as PointFeatureNode).point;
        final lat = point.latitude;
        final lng = point.longitude;
        children.addAll([
          const SizedBox(height: 12),
          _googleMapsButton(ref, lat, lng),
        ]);
      }

      // 全フィーチャ共通: 削除ボタンを追加
      children.addAll([
        const SizedBox(height: 12),
        if (onOpenInTree != null) ...[
          _openInTreeButton(node),
          const SizedBox(height: 8),
        ],
        _deleteButton(ref, key: TutorialTargets.deleteButton),
      ]);

      // タイトルをシンプルに（PointFeatureNode → Point等）
      String displayTitle = t.featureDetail.typeFeature;
      if (feature is PointFeatureNode) {
        displayTitle = t.featureDetail.typePoint;
      } else if (feature is LineFeatureNode) {
        displayTitle = t.featureDetail.typeLine;
      } else if (feature is PolygonFeatureNode) {
        displayTitle = t.featureDetail.typePolygon;
      }
      
      return _buildPanel(
        context,
        ref,
        title: displayTitle,
        // 「編集」は見出しに（パネルの下にあると送らないと見えなかった）。押すとパネルのまま編集に替わる
        action: FilledButton.tonalIcon(
          key: TutorialTargets.editButton,
          // 読み取り専用レイヤ（shp・GeoJSON など）なら「gpkg に変換して編集」を知らせる（start の中で断る）
          onPressed: () => ref.read(featureEditorProvider.notifier).start(feature),
          icon: const Icon(Icons.edit, size: 16),
          label: Text(t.featureDetail.edit),
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        children: children,
      );
    }
    return const SizedBox.shrink();
  }

  static const _small = TextStyle(fontSize: 11);

  /// 「名前: 値」の 1 行（値は折り返す）
  static Widget _labelRow(String label, String value, {TextStyle? style}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(value, style: style)),
        ],
      );

  /// Google Maps のリンクをコピーするボタン（長押しで開く。開くのは隠し機能扱い）
  Widget _googleMapsButton(WidgetRef ref, double lat, double lng) => SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: () => _copyGoogleMapsLink(ref, lat, lng),
          onLongPress: () => _openInGoogleMaps(ref, lat, lng),
          icon: const Icon(Icons.link, size: 16),
          label: Text(t.featureDetail.copyGoogleMapsLink),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green.shade50,
            foregroundColor: Colors.green.shade700,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 8),
          ),
        ),
      );

  /// 長押しで消すボタン
  /// レイヤツリーでそのフィーチャ・写真がある場所を開くボタン
  Widget _openInTreeButton(LayerTreeNode target) => SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: () => onOpenInTree?.call(target),
          icon: const Icon(Icons.account_tree_outlined, size: 16),
          label: Text(t.featureDetail.openInTree),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue.shade50,
            foregroundColor: Colors.blue.shade700,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 8),
          ),
        ),
      );

  /// 長押しで消すボタン
  Widget _deleteButton(WidgetRef ref, {Key? key}) => LongPressDeleteButton(
        key: key,
        label: t.featureDetail.delete,
        onDelete: () => _handleDelete(ref),
      );

  static Uri _googleMapsWebUri(double lat, double lng) =>
      Uri.parse('https://www.google.com/maps?q=$lat,$lng');

  /// Google Maps のリンクをクリップボードへ（LINE 等に貼る用途が主）
  Future<void> _copyGoogleMapsLink(WidgetRef ref, double lat, double lng) async {
    await Clipboard.setData(
      ClipboardData(text: _googleMapsWebUri(lat, lng).toString()),
    );
    ref.read(notificationCenterProvider.notifier).add(
      title: t.featureDetail.googleMapsLinkCopied,
      level: NotificationLevel.success,
    );
  }

  /// Google Mapsでポイントを開く（ボタン長押し）
  /// Android: geo: intentでGoogle Mapsアプリを優先起動
  /// PC/アプリなし: https:// URLでブラウザにフォールバック
  Future<void> _openInGoogleMaps(WidgetRef ref, double lat, double lng) async {
    // Android向け: geo: URIでGoogle Mapsアプリを直接起動
    final geoUri = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
    final webUri = _googleMapsWebUri(lat, lng);

    try {
      if (await canLaunchUrl(geoUri)) {
        await launchUrl(geoUri);
      } else {
        // PC or Google Maps未インストール → ブラウザで開く
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      // 両方失敗した場合
      ref.read(notificationCenterProvider.notifier).add(
        title: t.featureDetail.googleMapsOpenFailed,
        detail: e.toString(),
        level: NotificationLevel.error,
      );
    }
  }

  /// フィーチャ/写真を削除
  Future<void> _handleDelete(WidgetRef ref) async {
    final target = feature as LayerTreeNode; // FeatureNode / ImageNode / OverlayImageNode はいずれも LayerTreeNode
    // 読み取り専用レイヤ（shp・GeoJSON など）の地物は消さない
    if (refuseReadOnlyEditBy(ref.read, target)) return;
    // 選択解除でウィジェットがアンマウントされるため、先にNotifier参照をキャプチャ
    final selectionNotifier = ref.read(selectedFeaturesProvider.notifier);
    final refreshNotifier = ref.read(featureRefreshTriggerProvider.notifier);
    final notifNotifier = ref.read(notificationCenterProvider.notifier);
    try {
      // 1. 選択解除 → パネルが消える → ファイル参照が無くなる
      final layer = target is FeatureNode ? target.parent : null;
      final tutorial = ref.read(tutorialProvider.notifier);
      selectionNotifier.remove(target);
      // 2. UIリビルドを確実に挟む
      await Future<void>.delayed(Duration.zero);
      // 3. ファイル/DB削除
      await target.dispose();
      refreshNotifier.trigger();
      tutorial.report(FeatureDeleted(layer));
      notifNotifier.add(
        title: t.featureDetail.deleted,
        level: NotificationLevel.success,
      );
    } catch (e) {
      notifNotifier.add(
        title: t.featureDetail.deleteFailed,
        detail: e.toString(),
        level: NotificationLevel.error,
      );
    }
  }

  /// パネルの枠は [InfoPanelCard]（複数選択・現在位置のカードと共通）
  Widget _buildPanel(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required List<Widget> children,
    Widget? action,
  }) =>
      InfoPanelCard(
        title: title,
        action: action,
        onClose: () => ref.read(selectedFeaturesProvider.notifier).clear(),
        children: children,
      );

  /// 現在位置（擬似フィーチャ）の GPS 情報
  Widget _buildCurrentLocation(
    BuildContext context,
    WidgetRef ref,
    CurrentLocationNode node,
  ) {
    final info = node.gpsInfo;
    final active = info?.isActive ?? false;
    final lat = info?.latitude;
    final lon = info?.longitude;
    final accuracy = info?.accuracy;
    final satellites = info?.satelliteCount;
    final hdop = info?.hdop;
    final sourceName = info?.sourceName ?? t.gps.unknownDevice;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(child: Text(value)),
            ],
          ),
        );

    return _buildPanel(
      context,
      ref,
      title: t.gpsPanel.title,
      children: [
        if (!active) row(t.gpsPanel.status, t.gps.acquiring),
        if (lat != null && lon != null)
          row(t.gpsPanel.position, '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}'),
        if (accuracy != null) row(t.gpsPanel.accuracy, '±${accuracy.toStringAsFixed(1)} m'),
        if (satellites != null) row(t.gpsPanel.satellites, '$satellites'),
        if (hdop != null) row('HDOP', hdop.toStringAsFixed(2)),
        row(t.gpsPanel.source, sourceName),
        ValueListenableBuilder<double?>(
          valueListenable: node.headingNotifier,
          builder: (_, heading, _) => heading == null
              ? const SizedBox.shrink()
              : row(t.gpsPanel.heading, '${heading.toStringAsFixed(0)}°'),
        ),
      ],
    );
  }
}

/// 情報パネルの属性の行。QGIS の「地物情報の表示」と同じく、列は別名、値は表示する形
/// （真偽は「はい／いいえ」、ValueMap・ValueRelation は表示名、日付は見せる書式）で出す。
/// Hidden の列も出す（QGIS の地物情報の表示も出す）。ValueRelation の表示名は参照先の表を読むので、
/// 読み終わるまでは値のまま出す
class _AttributeRows extends StatefulWidget {
  const _AttributeRows({required this.node, required this.entries});

  final FeatureNode node;
  final List<MapEntry<String, dynamic>> entries;

  @override
  State<_AttributeRows> createState() => _AttributeRowsState();
}

class _AttributeRowsState extends State<_AttributeRows> {
  QgisForm? _form;
  Map<String, List<QgisValueOption>> _relations = const {};

  @override
  void initState() {
    super.initState();
    _loadRelations();
  }

  @override
  void didUpdateWidget(_AttributeRows old) {
    super.didUpdateWidget(old);
    if (!identical(old.node.parent.qgisFormIfLoaded, widget.node.parent.qgisFormIfLoaded)) _loadRelations();
  }

  void _loadRelations() {
    final layer = widget.node.parent;
    final form = layer.qgisFormIfLoaded;
    _form = form;
    _relations = const {};
    if (form == null || !form.fields.values.any((f) => f.kind == QgisWidgetKind.valueRelation)) return;
    final loaded = QgisFormOptions.relationsIfLoaded(form);
    if (loaded != null) {
      _relations = loaded;
      return;
    }
    QgisFormOptions.relations(layer, form).then((r) {
      if (mounted && identical(_form, form)) setState(() => _relations = r);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final layer = node.parent;
    final props = node.properties;
    final form = layer.qgisFormIfLoaded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in widget.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4.0),
            child: FeatureDetailPanel._labelRow(
              '${attributeLabel(entry.key, form)}: ',
              attributeDisplayText(
                props[entry.key] ?? entry.value,
                form: form?.fields[entry.key],
                sqlType: layer.columnSqlTypes[entry.key] ?? '',
                relationOptions: _relations[entry.key],
              ),
            ),
          ),
      ],
    );
  }
}

/// 公式オープンデータ（林班・国有林・地質図など）の読み取り専用詳細カード
class _OfficialFeatureCard extends ConsumerStatefulWidget {
  const _OfficialFeatureCard({
    required this.node,
    required this.googleMapsButton,
    this.onOpenInTree,
  });

  final OfficialFeatureNode node;
  final void Function(LayerTreeNode target)? onOpenInTree;
  final Widget Function(WidgetRef ref, double lat, double lng) googleMapsButton;

  @override
  ConsumerState<_OfficialFeatureCard> createState() => _OfficialFeatureCardState();
}

class _OfficialFeatureCardState extends ConsumerState<_OfficialFeatureCard> {
  Map<String, String>? _loadedAttrs;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _kickLoad();
  }

  @override
  void didUpdateWidget(_OfficialFeatureCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node != widget.node) {
      _loadedAttrs = null;
      _loading = false;
      _kickLoad();
    }
  }

  void _kickLoad() {
    final loader = widget.node.lazyAttributesLoader;
    if (loader == null || widget.node.attributes.isNotEmpty) return;
    _loading = true;
    final target = widget.node;
    loader().then((res) {
      if (!mounted || widget.node != target) return;
      setState(() {
        _loading = false;
        _loadedAttrs = res ?? const {};
      });
    }, onError: (Object _) {
      if (!mounted || widget.node != target) return;
      setState(() {
        _loading = false;
        _loadedAttrs = const {};
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final attrs = node.attributes.isNotEmpty ? node.attributes : (_loadedAttrs ?? const {});
    final parts = node.silhouetteParts;
    final double? areaM2 = parts.isNotEmpty && parts.first.length >= 3
        ? Geodesic.polygonArea(parts)
        : null;

    return InfoPanelCard(
      title: node.title,
      onClose: () => ref.read(selectedFeaturesProvider.notifier).clear(),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: node.spec.accentColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: node.spec.accentColor.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(node.spec.icon, size: 16, color: node.spec.accentColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t.officialLayer.readOnlyNote,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: node.spec.accentColor,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (areaM2 != null && areaM2 > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: FeatureDetailPanel._labelRow(
              t.featureDetail.areaLabel,
              Geodesic.formatArea(areaM2),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: FeatureDetailPanel._labelRow(
            t.featureDetail.coordLabel,
            '${node.tapPoint.latitude.toStringAsFixed(6)}, ${node.tapPoint.longitude.toStringAsFixed(6)}',
            style: FeatureDetailPanel._small,
          ),
        ),
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(t.officialLayer.loadingAttributes, style: const TextStyle(fontSize: 12)),
              ],
            ),
          )
        else if (attrs.isEmpty && node.lazyAttributesLoader != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              t.officialLayer.noDataAtPoint,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          )
        else
          for (final entry in attrs.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: FeatureDetailPanel._labelRow('${entry.key}: ', entry.value),
            ),
        const SizedBox(height: 6),
        FeatureDetailPanel._labelRow(
          t.officialLayer.sourceLabel,
          node.spec.attribution,
          style: FeatureDetailPanel._small,
        ),
        const SizedBox(height: 10),
        widget.googleMapsButton(ref, node.tapPoint.latitude, node.tapPoint.longitude),
        if (widget.onOpenInTree != null && node.parent != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => widget.onOpenInTree!(node.parent!),
              icon: const Icon(Icons.account_tree_outlined, size: 16),
              label: Text(t.featureDetail.openInTree),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade50,
                foregroundColor: Colors.blue.shade700,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
