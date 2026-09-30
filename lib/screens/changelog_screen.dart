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
/// チェンジログ表示画面
///
/// CHANGELOG.mdの内容をMarkdownとしてレンダリングする。
/// 画面表示時に既読マークを付ける。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../i18n/strings.g.dart';
import '../services/changelog_service.dart';

/// チェンジログ表示画面
class ChangelogScreen extends StatefulWidget {
  /// 画面を閉じる際に呼ばれるコールバック（未読状態の更新通知用）
  final VoidCallback? onRead;

  const ChangelogScreen({super.key, this.onRead});

  @override
  State<ChangelogScreen> createState() => _ChangelogScreenState();
}

class _ChangelogScreenState extends State<ChangelogScreen> {
  String? _content;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final content = await ChangelogService.instance.loadChangelog();
    // 既読としてマーク
    await ChangelogService.instance.markAsRead();
    if (mounted) {
      setState(() {
        _content = content;
        _isLoading = false;
      });
      // 呼び出し元に既読通知
      widget.onRead?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.changelog.title),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _content == null || _content!.isEmpty
              ? Center(
                  child: Text(
                    t.changelog.noContent,
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : _Sections(content: _content!, styleSheet: _styleSheet(context)),
    );
  }

  MarkdownStyleSheet _styleSheet(BuildContext context) => MarkdownStyleSheet.fromTheme(
                    Theme.of(context),
                  ).copyWith(
                    // h1スタイル
                    h1: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    // h2スタイル（バージョン見出し）
                    h2: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                    // h3スタイル（カテゴリ見出し）
                    h3: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    // 水平線のスタイル
                    horizontalRuleDecoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: Theme.of(context).dividerColor,
                          width: 1,
                        ),
                      ),
                    ),
                  );
}

/// 更新履歴を版（`## `）ごとに並べる。図解（Typst で書き出した SVG の切れ）がある版は図を、無い版は
/// 今までどおり Markdown を出す。
///
/// > [!IMPORTANT] 継ぎ目を見せない
/// > 図の切れは背景を持たず、文章と同じ左右の余白で縦に並べる（縦読み漫画のように、スクロールで次々に出る）。
/// > 切れは [ListView.builder] が見えるところだけ作るので、読み込みもスクロールに合わせて進む。
/// > 高さは縦横比で先に確保するので、読み込んでも画面はずれない。
/// > 図の版の文章は画面には出さず、読み上げ用に切れの意味（semantics）として持たせる
class _Sections extends StatefulWidget {
  const _Sections({required this.content, required this.styleSheet});

  final String content;
  final MarkdownStyleSheet styleSheet;

  /// `## ` の手前（`# 更新履歴` 等）と、版ごとのかたまりに分ける
  static List<String> split(String md) {
    final parts = <String>[];
    final buf = StringBuffer();
    for (final line in const LineSplitter().convert(md)) {
      if (line.startsWith('## ') && buf.isNotEmpty) {
        parts.add(buf.toString());
        buf.clear();
      }
      buf.writeln(line);
    }
    if (buf.isNotEmpty) parts.add(buf.toString());
    return parts;
  }

  @override
  State<_Sections> createState() => _SectionsState();
}

class _SectionsState extends State<_Sections> {
  /// 並べるもの。String は Markdown、[FigureChunk] は図の切れ
  late final Future<List<Object>> _items = _build();

  Future<List<Object>> _build() async {
    final items = <Object>[];
    for (final md in _Sections.split(widget.content)) {
      final figure = md.startsWith('## ')
          ? await ChangelogService.instance.figureFor(md.substring(3, md.indexOf('\n')).trim())
          : null;
      if (figure == null) {
        items.add(md);
      } else {
        items.addAll(figure);
        // 読み上げ用（1 切れ目にその版の文章を持たせる）
        _spoken[figure.first] = md;
      }
    }
    return items;
  }

  final _spoken = <FigureChunk, String>{};

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Object>>(
      future: _items,
      builder: (context, snap) {
        final items = snap.data;
        if (items == null) return const SizedBox.shrink();
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          itemCount: items.length,
          itemBuilder: (context, i) => switch (items[i]) {
            final FigureChunk c => Semantics(
                label: _spoken[c],
                excludeSemantics: true,
                child: AspectRatio(
                  aspectRatio: c.aspectRatio,
                  child: SvgPicture.asset(c.asset, fit: BoxFit.fitWidth),
                ),
              ),
            final Object md => MarkdownBody(data: md as String, selectable: true, styleSheet: widget.styleSheet),
          },
        );
      },
    );
  }
}
