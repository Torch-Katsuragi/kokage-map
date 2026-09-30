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

/// 更新履歴を版（`## `）ごとに畳んで並べる。見出し（版・日付・その版の一言）を押すと開き、
/// 図解（Typst で書き出した SVG の切れ）がある版は図を、無い版は Markdown を出す。いちばん新しい版だけ開いておく。
///
/// > [!IMPORTANT] 開いた版の中は継ぎ目を見せない
/// > 図の切れは背景を持たず、文章と同じ左右の余白で縦に並べる（縦読み漫画のように、スクロールで次々に出る）。
/// > 切れは [ListView.builder] が見えるところだけ作るので、読み込みもスクロールに合わせて進む。
/// > 高さは縦横比で先に確保するので、読み込んでも画面はずれない。
/// > 図の版の文章は画面には出さず、読み上げ用に切れの意味（semantics）として持たせる。
/// > 版と一言は図に描かず見出しに出す（開いたとき同じ字が二度出ないように）
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

/// 1 つの版
class _Version {
  _Version({required this.heading, required this.title, required this.body, required this.figure});

  /// `v0.7.3 — 2026/09/27`（md の `## ` の行）
  final String heading;

  /// その版の一言（図解の頭の一言。図が無ければ md の最初の `### `）
  final String title;

  /// 見出しの行を除いた md
  final String body;
  final Figure? figure;
}

/// 見出し（押すと開閉）
class _Header {
  const _Header(this.index);
  final int index;
}

/// 図の版の切れ（[first] なら読み上げ用にその版の文章を持つ）
class _Chunk {
  const _Chunk(this.chunk, this.version, {required this.first});
  final FigureChunk chunk;
  final _Version version;
  final bool first;
}

class _SectionsState extends State<_Sections> {
  late final Future<(String, List<_Version>)> _loaded = _load();

  /// 開いている版。いちばん新しい版だけ開いておく
  final _open = <int>{0};

  Future<(String, List<_Version>)> _load() async {
    var preamble = '';
    final versions = <_Version>[];
    for (final part in _Sections.split(widget.content)) {
      if (!part.startsWith('## ')) {
        // `# 更新履歴` は画面の題と重なるので出さない
        preamble = part.replaceAll(RegExp(r'^# .*$', multiLine: true), '');
        continue;
      }
      final nl = part.indexOf('\n');
      final heading = part.substring(3, nl).trim();
      final body = part.substring(nl + 1);
      final figure = await ChangelogService.instance.figureFor(heading);
      final firstH3 = RegExp(r'^### (.+)$', multiLine: true).firstMatch(body)?.group(1) ?? '';
      versions.add(_Version(
        heading: heading,
        title: figure?.title ?? firstH3,
        body: body,
        figure: figure,
      ));
    }
    return (preamble, versions);
  }

  List<Object> _items(String preamble, List<_Version> versions) => [
        if (preamble.trim().isNotEmpty) preamble,
        for (final (i, v) in versions.indexed) ...[
          _Header(i),
          if (_open.contains(i))
            if (v.figure != null)
              for (final (k, c) in v.figure!.chunks.indexed) _Chunk(c, v, first: k == 0)
            else
              v.body,
        ],
      ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(String, List<_Version>)>(
      future: _loaded,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) return const SizedBox.shrink();
        final (preamble, versions) = data;
        final items = _items(preamble, versions);
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          itemCount: items.length,
          itemBuilder: (context, i) => switch (items[i]) {
            _Header(:final index) => _VersionHeader(
                version: versions[index],
                open: _open.contains(index),
                onTap: () => setState(() => _open.contains(index) ? _open.remove(index) : _open.add(index)),
              ),
            _Chunk(:final chunk, :final version, :final first) => Semantics(
                label: first ? version.body : null,
                excludeSemantics: true,
                child: AspectRatio(
                  aspectRatio: chunk.aspectRatio,
                  child: SvgPicture.asset(chunk.asset, fit: BoxFit.fitWidth),
                ),
              ),
            final Object md => MarkdownBody(data: md as String, selectable: true, styleSheet: widget.styleSheet),
          },
        );
      },
    );
  }
}

/// 版の見出し。図の頭と同じ字の並び（小さな版と日付、その下に大きな一言）
class _VersionHeader extends StatelessWidget {
  const _VersionHeader({required this.version, required this.open, required this.onTap});

  final _Version version;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)))),
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      version.heading,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF1565C0),
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (version.title.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        version.title,
                        style: theme.textTheme.titleMedium?.copyWith(fontSize: 18, fontWeight: FontWeight.bold, height: 1.35),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
      ),
    );
  }
}
