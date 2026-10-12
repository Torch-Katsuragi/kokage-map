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
// こかげマップ: 属性テーブルの下のページ送り
//
// TrinaLazyPagination の既定の見た目は横幅を固定で使い、縦向きのスマホ（約 412 dp）では
// 右端がはみ出していた（2026-10-12 に Pixel 9 で「OVERFLOWED BY 76 PIXELS」）。
// ボタンを詰め、幅が足りなければ「先頭へ・末尾へ」と件数を畳む。

import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

/// ページ送り（件数・|< < ページ / 総ページ > >|・1 ページの件数）
class AttributeTablePager extends StatelessWidget {
  const AttributeTablePager({
    super.key,
    required this.page,
    required this.totalPage,
    required this.totalRecords,
    required this.pageSize,
    required this.pageSizes,
    required this.onPage,
    required this.onPageSize,
    this.height = 40,
    this.iconColor = Colors.black54,
    this.disabledIconColor = Colors.black26,
    this.activatedColor = Colors.blue,
  });

  /// [TrinaLazyPagination.builder] から作る
  factory AttributeTablePager.fromState(
    TrinaLazyPaginationState s, {
    required List<int> pageSizes,
    void Function(int pageSize)? onPageSizeChanged,
  }) {
    final style = s.stateManager.style;
    return AttributeTablePager(
      page: s.page,
      totalPage: s.totalPage,
      totalRecords: s.totalRecords,
      pageSize: s.pageSize,
      pageSizes: pageSizes,
      onPage: s.setPage,
      onPageSize: (size) {
        s.setPageSize(size);
        onPageSizeChanged?.call(size);
      },
      height: s.stateManager.footerHeight,
      iconColor: style.iconColor,
      disabledIconColor: style.disabledIconColor,
      activatedColor: style.activatedBorderColor,
    );
  }

  final int page;
  final int totalPage;
  final int? totalRecords;
  final int pageSize;
  final List<int> pageSizes;
  final void Function(int page) onPage;
  final void Function(int pageSize) onPageSize;
  final double height;
  final Color iconColor;
  final Color disabledIconColor;
  final Color activatedColor;

  /// これより狭いと「先頭へ・末尾へ」を出さない
  static const double compactWidth = 340;

  /// これより狭いと左の件数も出さない（総件数はページの横の [n] に残る）
  static const double narrowWidth = 280;

  @override
  Widget build(BuildContext context) {
    final first = page < 2;
    final last = page >= totalPage;
    return LayoutBuilder(
      builder: (context, size) {
        final w = size.maxWidth;
        final showEnds = w >= compactWidth;
        final showCount = w >= narrowWidth && totalRecords != null;
        return SizedBox(
          height: height,
          child: Row(
            children: [
              if (showCount)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.table_rows, color: iconColor, size: 16),
                      const SizedBox(width: 2),
                      Text('$totalRecords', style: TextStyle(color: iconColor, fontSize: 13)),
                    ],
                  ),
                ),
              const Spacer(),
              if (showEnds) _button(Icons.first_page, first ? null : () => onPage(1)),
              _button(Icons.navigate_before, first ? null : () => onPage(page - 1)),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    totalRecords == null ? '$page / $totalPage' : '$page / $totalPage [$totalRecords]',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: activatedColor, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ),
              _button(Icons.navigate_next, last ? null : () => onPage(page + 1)),
              if (showEnds) _button(Icons.last_page, last ? null : () => onPage(totalPage)),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: DropdownButton<int>(
                  value: pageSizes.contains(pageSize) ? pageSize : null,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  focusColor: Colors.transparent,
                  icon: Icon(Icons.view_list, color: iconColor, size: 18),
                  items: [
                    for (final s in pageSizes)
                      DropdownMenuItem(
                        value: s,
                        child: Text('$s', style: TextStyle(color: iconColor, fontSize: 13)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) onPageSize(v);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _button(IconData icon, VoidCallback? onPressed) => IconButton(
    icon: Icon(icon),
    iconSize: 20,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    color: iconColor,
    disabledColor: disabledIconColor,
    onPressed: onPressed,
  );
}
