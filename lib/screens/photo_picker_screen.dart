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
// 気づくことになっていた（松本 2026-10-01）。見た目は Google フォトに寄せ、サムネイルを主役にする（同日）:
// - 日付ごとの見出し・すき間の細い正方形・上の題名でアルバム切り替え
// - 1 回押すとその 1 枚をすぐ取り込む。長押しで複数選択に入り、選んだ写真は青枠。取り込むボタンは複数選択のときだけ
// - 位置ありには何もしない。位置なしは薄くして、白黒の「位置なし」の印を淡く重ねる
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

  /// 長押しで入る複数選択。入っていなければ 1 回押すとすぐ取り込む
  bool _multi = false;

  /// 位置の有無（id → 有り）。読み終えた写真だけ入る
  final _hasLocation = <String, bool>{};

  /// 位置を読んでいる最中の写真（二度読まない）
  final _reading = <String>{};
  bool _onlyWithLocation = false;

  /// 日付の見出しと並び。写真の追加・絞り込みの切り替えで組み直す
  /// （位置を 1 枚読むたびの組み直しで毎回全部を並べ直さない）
  List<_Row>? _rowsCache;
  DateTime? _rowsDay;

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
      _rowsCache = null;
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
      _rowsCache = null;
      _loading = false;
    });
  }

  Future<void> _checkLocation(AssetEntity a) async {
    if (_hasLocation.containsKey(a.id) || !_reading.add(a.id)) return;
    bool has = false;
    try {
      final ll = await a.latlngAsync();
      has = ll != null && (ll.latitude != 0 || ll.longitude != 0);
    } catch (_) {}
    _reading.remove(a.id);
    if (!mounted) return;
    setState(() {
      _hasLocation[a.id] = has;
      // 位置ありだけを出しているときは並びが変わる
      if (_onlyWithLocation) _rowsCache = null;
    });
  }

  void _toggleOnlyWithLocation() => setState(() {
        _onlyWithLocation = !_onlyWithLocation;
        _rowsCache = null;
      });

  void _tap(AssetEntity a) {
    if (!_multi) {
      Navigator.pop(context, [a]);
      return;
    }
    setState(() {
      if (!_selected.remove(a)) _selected.add(a);
      if (_selected.isEmpty) _multi = false;
    });
  }

  void _longPress(AssetEntity a) {
    setState(() {
      _multi = true;
      if (!_selected.contains(a)) _selected.add(a);
    });
  }

  void _endMulti() => setState(() {
        _multi = false;
        _selected.clear();
      });

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

  /// 上の題名: 今のアルバム。2 つ以上あれば押して切り替える
  Widget _buildAlbumTitle() {
    final album = _album;
    return InkWell(
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
    );
  }

  /// 写真 1 枚。組むときに位置を読み始める（画面に出た枠から順に読む）
  Widget _buildTile(AssetEntity a, {GlobalKey? tutorialKey}) => Builder(builder: (_) {
        _checkLocation(a);
        return _Tile(
          key: tutorialKey,
          asset: a,
          hasLocation: _hasLocation[a.id],
          selected: _selected.contains(a),
          onTap: () => _tap(a),
          onLongPress: () => _longPress(a),
        );
      });

  /// 見せる写真の並び（日付が替わったら見出しの「今日」「昨日」を付け直す）
  List<_Row> _currentRows() {
    final today = _day(DateTime.now());
    if (_rowsCache == null || _rowsDay != today) {
      _rowsDay = today;
      _rowsCache = _rows(_shown());
    }
    return _rowsCache!;
  }

  List<AssetEntity> _shown() =>
      _onlyWithLocation ? _assets.where((a) => _hasLocation[a.id] == true).toList() : _assets;

  @override
  Widget build(BuildContext context) {
    final rows = _currentRows();
    final theme = Theme.of(context);
    // チュートリアルの案内先: 最初に見つかった位置つき・位置なしの写真（位置ありだけのときは位置なしは並ばない）
    final firstLocated = _assets.where((x) => _hasLocation[x.id] == true).firstOrNull;
    final firstUnlocated =
        _onlyWithLocation ? null : _assets.where((x) => _hasLocation[x.id] == false).firstOrNull;

    return PopScope(
      canPop: !_multi,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endMulti(); // 複数選択中の「戻る」は選択をやめるだけ
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => _multi ? _endMulti() : Navigator.pop(context),
          ),
          title: _multi ? Text(t.photoPicker.selected(count: _selected.length)) : _buildAlbumTitle(),
          actions: [
            IconButton(
              tooltip: t.photoPicker.onlyWithLocation,
              isSelected: _onlyWithLocation,
              icon: const Icon(Icons.location_on_outlined),
              selectedIcon: Icon(Icons.location_on, color: theme.colorScheme.primary),
              onPressed: _toggleOnlyWithLocation,
            ),
          ],
        ),
        body: NotificationListener<ScrollNotification>(
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
                              child: _buildTile(
                                a,
                                tutorialKey: identical(a, firstLocated)
                                    ? TutorialTargets.locatedPhoto
                                    : identical(a, firstUnlocated)
                                        ? TutorialTargets.unlocatedPhoto
                                        : null,
                              ),
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
        // 取り込むボタンは複数選択のときだけ（1 枚なら押した時点で取り込む）
        bottomNavigationBar: _multi
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: FilledButton(
                    key: TutorialTargets.importButton,
                    onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, List<AssetEntity>.of(_selected)),
                    child: Text(t.photoPicker.import(count: _selected.length)),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// 写真 1 枚。選んだら縮んで角丸の青枠。位置なしは薄くして「位置なし」の印を淡く重ねる
class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.asset,
    required this.hasLocation,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final AssetEntity asset;

  /// null は読み中
  final bool? hasLocation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unlocated = hasLocation == false;
    final photo = Stack(
      fit: StackFit.expand,
      children: [
        // 位置なしは薄く（背景の白に寄せる）
        Opacity(
          opacity: unlocated ? 0.45 : 1,
          child: AssetEntityImage(
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
        ),
        if (unlocated)
          const Center(
            child: Opacity(opacity: 0.6, child: SizedBox(width: 34, height: 34, child: NoLocationIcon())),
          ),
      ],
    );
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      // 選ぶと縮んで角が丸くなり、青い縁が付く。0.14 秒で形を変える（押した手応え。繰り返さない）
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: selected ? 1 : 0),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: photo,
        builder: (context, k, child) {
          final radius = BorderRadius.circular(14 * k);
          return ColoredBox(
            // 縮んだすき間は淡い青
            // （transparent から lerp すると途中で灰色になるので、色はそのまま濃さだけ変える）
            color: scheme.primaryContainer.withValues(alpha: k),
            child: Padding(
              padding: EdgeInsets.all(9 * k),
              child: ClipRRect(
                borderRadius: radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    child!,
                    if (k > 0)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          border: Border.all(color: scheme.primary.withValues(alpha: k), width: 3),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 「位置なし」の印（白黒）。白い地図のピンを黒で縁取り、斜線で消す。
/// 明るい写真にも暗い写真にも埋もれないように、白と黒を両方使う
class NoLocationIcon extends StatelessWidget {
  const NoLocationIcon({super.key});

  @override
  Widget build(BuildContext context) => const CustomPaint(painter: _NoLocationPainter());
}

class _NoLocationPainter extends CustomPainter {
  const _NoLocationPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // ピン: 上が丸く下がとがった形
    final pin = Path()
      ..moveTo(w * 0.5, h * 0.94)
      ..cubicTo(w * 0.32, h * 0.70, w * 0.18, h * 0.52, w * 0.18, h * 0.38)
      ..arcToPoint(Offset(w * 0.82, h * 0.38), radius: Radius.circular(w * 0.32))
      ..cubicTo(w * 0.82, h * 0.52, w * 0.68, h * 0.70, w * 0.5, h * 0.94)
      ..close();
    final hole = Path()..addOval(Rect.fromCircle(center: Offset(w * 0.5, h * 0.38), radius: w * 0.11));
    final shape = Path.combine(PathOperation.difference, pin, hole);
    final edge = w * 0.07;
    canvas.drawPath(shape, Paint()..color = Colors.white);
    canvas.drawPath(shape, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = edge
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.black);
    // 斜線（黒の太線の上に白の細線。どちらの地でも見える）
    final a = Offset(w * 0.12, h * 0.10);
    final b = Offset(w * 0.88, h * 0.90);
    canvas.drawLine(a, b, Paint()
      ..strokeWidth = edge * 2.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.black);
    canvas.drawLine(a, b, Paint()
      ..strokeWidth = edge * 0.9
      ..strokeCap = StrokeCap.round
      ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_NoLocationPainter old) => false;
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
