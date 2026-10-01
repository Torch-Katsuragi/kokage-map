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
// 写真の選択（アプリ内のギャラリー）: 位置情報の有り無しを選ぶ前に見せる
//
// OS の写真ピッカーは見た目を変えられないので、取り込んでから「位置が入っていなかった」と
// 気づくことになっていた（松本 2026-10-01）。ここでは端末の写真を自前で並べ、
// 位置ありは緑の枠とピン、位置なしは「位置なし」の札で見分ける。
//
// 位置は 1 枚ずつ EXIF を読む（Android 10 以降は MediaStore に緯度経度の列が無い）。
// 画面に出た枠から順に読み、結果は覚えておく。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../i18n/strings.g.dart';
import '../tutorial/tutorial.dart';

class PhotoPickerScreen extends StatefulWidget {
  const PhotoPickerScreen({super.key});

  /// 選んだ写真を返す。権限が無く開けないときは null（呼び手は OS のピッカーに切り替える）
  static Future<List<AssetEntity>?> pick(BuildContext context) async {
    // 全ファイルアクセスがあれば写真も読める。photo_manager に自前の権限確認をさせると
    // 「写真と動画へのアクセス」をもう一度聞いてしまうので、そのときは確認を飛ばす
    if (await Permission.manageExternalStorage.isGranted) {
      await PhotoManager.setIgnorePermissionCheck(true);
    } else {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) return null;
    }
    if (!context.mounted) return null;
    return Navigator.of(context).push<List<AssetEntity>>(
      MaterialPageRoute(builder: (_) => const PhotoPickerScreen(), fullscreenDialog: true),
    ).then((v) => v ?? const []);
  }

  @override
  State<PhotoPickerScreen> createState() => _PhotoPickerScreenState();
}

class _PhotoPickerScreenState extends State<PhotoPickerScreen> {
  static const _pageSize = 120;

  AssetPathEntity? _all;
  final _assets = <AssetEntity>[];
  int _total = 0;
  bool _loading = false;
  final _selected = <AssetEntity>[];

  /// 位置の有無（id → 有り）。読み終えた写真だけ入る
  final _hasLocation = <String, bool>{};
  bool _onlyWithLocation = false;

  @override
  void initState() {
    super.initState();
    // 組み立ての最中にプロバイダを変えられないので、描き終えてから知らせる
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ProviderScope.containerOf(context, listen: false).read(tutorialProvider.notifier).report(const PhotoPickerOpened());
    });
    _init();
  }

  Future<void> _init() async {
    // 新しい写真から（現場で撮った直後に取り込むことが多い）
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)]),
    );
    if (!mounted || paths.isEmpty) return;
    _all = paths.first;
    _total = await _all!.assetCountAsync;
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final all = _all;
    if (all == null || _loading || _assets.length >= _total) return;
    _loading = true;
    final page = await all.getAssetListPaged(page: _assets.length ~/ _pageSize, size: _pageSize);
    if (!mounted) return;
    setState(() {
      _assets.addAll(page);
      _loading = false;
    });
  }

  Future<void> _checkLocation(AssetEntity a) async {
    if (_hasLocation.containsKey(a.id)) return;
    _hasLocation[a.id] = false; // 読み中に二度読まない
    bool has = false;
    try {
      final ll = await a.latlngAsync();
      has = ll != null && (ll.latitude != 0 || ll.longitude != 0);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _hasLocation[a.id] = has);
  }

  void _toggle(AssetEntity a) {
    setState(() {
      if (!_selected.remove(a)) _selected.add(a);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _onlyWithLocation ? _assets.where((a) => _hasLocation[a.id] == true).toList() : _assets;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.photoPicker.title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(t.photoPicker.onlyWithLocation),
              selected: _onlyWithLocation,
              onSelected: (v) => setState(() => _onlyWithLocation = v),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            key: TutorialTargets.pickerLegend,
            width: double.infinity,
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const _LocationMark(),
                const SizedBox(width: 6),
                Expanded(child: Text(t.photoPicker.legend, style: Theme.of(context).textTheme.bodySmall)),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 800) _loadMore();
                return false;
              },
              child: GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final a = shown[i];
                  _checkLocation(a);
                  final order = _selected.indexOf(a);
                  // チュートリアルの案内先: 最初に見つかった位置つきの写真
                  final firstLocated = shown.firstWhere((x) => _hasLocation[x.id] == true, orElse: () => a);
                  return _Tile(
                    key: _hasLocation[a.id] == true && identical(firstLocated, a) ? TutorialTargets.locatedPhoto : null,
                    asset: a,
                    hasLocation: _hasLocation[a.id],
                    order: order < 0 ? null : order + 1,
                    onTap: () => _toggle(a),
                  );
                },
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: FilledButton(
            key: _selected.isEmpty ? null : TutorialTargets.importButton,
            onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, List<AssetEntity>.of(_selected)),
            child: Text(_selected.isEmpty ? t.photoPicker.choose : t.photoPicker.import(count: _selected.length)),
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.asset, required this.hasLocation, required this.order, required this.onTap});

  final AssetEntity asset;

  /// null は読み中
  final bool? hasLocation;
  final int? order;
  final VoidCallback onTap;

  static const _green = Color(0xFF2E7D32);

  @override
  Widget build(BuildContext context) {
    final selected = order != null;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AssetEntityImage(asset, isOriginal: false, thumbnailSize: const ThumbnailSize.square(240), fit: BoxFit.cover),
          // 位置あり: 緑の枠とピン。位置なし: 下に札
          if (hasLocation == true) ...[
            const DecoratedBox(decoration: BoxDecoration(border: Border.fromBorderSide(BorderSide(color: _green, width: 3)))),
            const Positioned(left: 4, bottom: 4, child: _LocationMark()),
          ],
          if (hasLocation == false)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(t.photoPicker.noLocation,
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          if (selected) Container(color: Colors.white38),
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? Theme.of(context).colorScheme.primary : Colors.black26,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: selected
                  ? Text('$order', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 位置ありの印（緑の丸にピン）
class _LocationMark extends StatelessWidget {
  const _LocationMark();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(color: _Tile._green, shape: BoxShape.circle),
        child: const Icon(Icons.place, size: 14, color: Colors.white),
      );
}
