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
// 気づくことになっていた（松本 2026-10-01）。見た目は Google フォトに寄せる（同日）:
// 日付ごとの見出し・すき間の細い正方形・上の題名でアルバム切り替え・選ぶと縮んで角が丸くなるタイル。
// 位置ありは細い緑の縁と緑のピン、位置なしは灰色の「位置なし」の印。
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

const _green = Color(0xFF2E7D32);

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

/// 一覧の 1 行（日付の見出し、または写真の並び）
sealed class _Row {}

class _Header extends _Row {
  _Header(this.label);
  final String label;
}

class _Photos extends _Row {
  _Photos(this.assets);
  final List<AssetEntity> assets;
}

class _PhotoPickerScreenState extends State<PhotoPickerScreen> {
  static const _pageSize = 120;
  static const _columns = 4;
  static const _gap = 2.0;

  List<AssetPathEntity> _albums = const [];
  AssetPathEntity? _album;
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
    // 新しい写真から（現場で撮った直後に取り込むことが多い）。先頭が「すべて」
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)]),
    );
    if (!mounted || albums.isEmpty) return;
    _albums = albums;
    await _openAlbum(albums.first);
  }

  Future<void> _openAlbum(AssetPathEntity album) async {
    final total = await album.assetCountAsync;
    if (!mounted) return;
    setState(() {
      _album = album;
      _total = total;
      _assets.clear();
      _loading = false;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loading || _assets.length >= _total) return;
    _loading = true;
    final page = await album.getAssetListPaged(page: _assets.length ~/ _pageSize, size: _pageSize);
    if (!mounted || album != _album) return;
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

  // ── 日付の見出し ──

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  String _dayLabel(DateTime day) {
    final today = _day(DateTime.now());
    if (day == today) return t.photoPicker.today;
    if (day == today.subtract(const Duration(days: 1))) return t.photoPicker.yesterday;
    final w = t.photoPicker.weekdays.split(',')[day.weekday - 1];
    return day.year == today.year
        ? t.photoPicker.dateThisYear(m: day.month, d: day.day, w: w)
        : t.photoPicker.dateOtherYear(y: day.year, m: day.month, d: day.day, w: w);
  }

  /// 日付ごとに見出しを挟み、[_columns] 枚ずつの並びに分ける
  List<_Row> _rows(List<AssetEntity> shown) {
    final rows = <_Row>[];
    DateTime? current;
    var line = <AssetEntity>[];
    void flush() {
      if (line.isNotEmpty) rows.add(_Photos(line));
      line = <AssetEntity>[];
    }

    for (final a in shown) {
      final day = _day(a.createDateTime);
      if (day != current) {
        flush();
        rows.add(_Header(_dayLabel(day)));
        current = day;
      }
      line.add(a);
      if (line.length == _columns) flush();
    }
    flush();
    return rows;
  }

  // ── アルバム ──

  Future<void> _chooseAlbum() async {
    final picked = await showModalBottomSheet<AssetPathEntity>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final album in _albums)
              ListTile(
                leading: _AlbumCover(album),
                title: Text(album.isAll ? t.photoPicker.allPhotos : album.name),
                trailing: FutureBuilder<int>(
                  future: album.assetCountAsync,
                  builder: (_, s) => Text(s.hasData ? '${s.data}' : ''),
                ),
                selected: album == _album,
                onTap: () => Navigator.pop(ctx, album),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != _album) await _openAlbum(picked);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _onlyWithLocation ? _assets.where((a) => _hasLocation[a.id] == true).toList() : _assets;
    final rows = _rows(shown);
    final theme = Theme.of(context);
    final selecting = _selected.isNotEmpty;
    final album = _album;
    // チュートリアルの案内先: 最初に見つかった位置つきの写真
    final firstLocated = shown.where((x) => _hasLocation[x.id] == true).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => selecting ? setState(_selected.clear) : Navigator.pop(context),
        ),
        title: selecting
            ? Text(t.photoPicker.selected(count: _selected.length))
            : InkWell(
                onTap: _albums.length > 1 ? _chooseAlbum : null,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          album == null || album.isAll ? t.photoPicker.allPhotos : album.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_albums.length > 1) const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
        actions: [
          IconButton(
            tooltip: t.photoPicker.onlyWithLocation,
            isSelected: _onlyWithLocation,
            icon: const Icon(Icons.location_on_outlined),
            selectedIcon: const Icon(Icons.location_on, color: _green),
            onPressed: () => setState(() => _onlyWithLocation = !_onlyWithLocation),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            key: TutorialTargets.pickerLegend,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                const _LocationMark(true),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _onlyWithLocation ? t.photoPicker.onlyWithLocationOn : t.photoPicker.legend,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 800) _loadMore();
                return false;
              },
              child: LayoutBuilder(
                builder: (context, box) {
                  final side = (box.maxWidth - _gap * (_columns - 1)) / _columns;
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) => switch (rows[i]) {
                      _Header(:final label) => Padding(
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                          child: Text(label, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                        ),
                      _Photos(:final assets) => Padding(
                          padding: const EdgeInsets.only(bottom: _gap),
                          child: Row(
                            children: [
                              for (final (j, a) in assets.indexed) ...[
                                if (j > 0) const SizedBox(width: _gap),
                                SizedBox(
                                  width: side,
                                  height: side,
                                  child: Builder(builder: (_) {
                                    _checkLocation(a);
                                    final order = _selected.indexOf(a);
                                    return _Tile(
                                      key: identical(a, firstLocated) ? TutorialTargets.locatedPhoto : null,
                                      asset: a,
                                      hasLocation: _hasLocation[a.id],
                                      order: order < 0 ? null : order + 1,
                                      onTap: () => _toggle(a),
                                    );
                                  }),
                                ),
                              ],
                            ],
                          ),
                        ),
                    },
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
            key: selecting ? TutorialTargets.importButton : null,
            onPressed: selecting ? () => Navigator.pop(context, List<AssetEntity>.of(_selected)) : null,
            child: Text(selecting ? t.photoPicker.import(count: _selected.length) : t.photoPicker.choose),
          ),
        ),
      ),
    );
  }
}

/// 写真 1 枚。選ぶと少し縮んで角が丸くなり、左上の丸に番号が付く（Google フォトと同じ見え方）
class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.asset, required this.hasLocation, required this.order, required this.onTap});

  final AssetEntity asset;

  /// null は読み中
  final bool? hasLocation;
  final int? order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = order != null;
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(selected ? 10 : 0);
    return GestureDetector(
      onTap: onTap,
      child: ColoredBox(
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 選んだら縮める（押した手応え。短く、繰り返さない）
            AnimatedPadding(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              padding: EdgeInsets.all(selected ? 10 : 0),
              child: ClipRRect(
                borderRadius: radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AssetEntityImage(
                      asset,
                      isOriginal: false,
                      thumbnailSize: const ThumbnailSize.square(240),
                      fit: BoxFit.cover,
                      // 縮小画像を作れない形式（TIFF など）は印だけ出す（例外の文字をそのまま出さない）
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.image_not_supported_outlined, color: scheme.outline),
                      ),
                    ),
                    if (hasLocation == true)
                      DecoratedBox(
                        decoration: BoxDecoration(border: Border.all(color: _green, width: 2.5), borderRadius: radius),
                      ),
                  ],
                ),
              ),
            ),
            if (hasLocation != null)
              Positioned(left: selected ? 14 : 5, bottom: selected ? 14 : 5, child: _LocationMark(hasLocation!)),
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? scheme.primary : Colors.black12,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: selected
                    ? Text('$order', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 位置の印。ありは緑の丸にピン、なしは灰色の丸に斜線のピン
class _LocationMark extends StatelessWidget {
  const _LocationMark(this.located);
  final bool located;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: located ? _green : Colors.black45, shape: BoxShape.circle),
        child: Icon(located ? Icons.place : Icons.location_off, size: 13, color: Colors.white),
      );
}

/// アルバムの表紙（いちばん新しい 1 枚）
class _AlbumCover extends StatelessWidget {
  const _AlbumCover(this.album);
  final AssetPathEntity album;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 48,
        height: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: FutureBuilder<List<AssetEntity>>(
            future: album.getAssetListRange(start: 0, end: 1),
            builder: (_, s) {
              final first = s.data?.firstOrNull;
              return first == null
                  ? ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest)
                  : AssetEntityImage(first, isOriginal: false, thumbnailSize: const ThumbnailSize.square(120), fit: BoxFit.cover);
            },
          ),
        ),
      );
}
