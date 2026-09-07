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
/// ユーザーガイド表示画面
///
/// assets/user_guide/{locale}.md の内容をMarkdownとしてレンダリングする。
/// カスタム記法 `:icon-xxx:` でFlutter Material Iconsをインライン表示。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../i18n/strings.g.dart';
import '../widgets/icon_markdown.dart';

/// ユーザーガイド表示画面
class UserGuideScreen extends StatefulWidget {
  const UserGuideScreen({super.key});

  @override
  State<UserGuideScreen> createState() => _UserGuideScreenState();
}

class _UserGuideScreenState extends State<UserGuideScreen> {
  String? _content;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final locale = LocaleSettings.currentLocale.languageCode;
    String content;
    try {
      content = await rootBundle.loadString('assets/user_guide/$locale.md');
    } catch (_) {
      // フォールバック: ja.md
      try {
        content = await rootBundle.loadString('assets/user_guide/ja.md');
      } catch (_) {
        content = '';
      }
    }
    if (mounted) {
      setState(() {
        _content = content;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.userGuide.title),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _content == null || _content!.isEmpty
              ? Center(
                  child: Text(
                    t.userGuide.noContent,
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : Markdown(
                  data: _content!,
                  selectable: true,
                  inlineSyntaxes: [IconInlineSyntax()],
                  builders: {'flutterIcon': IconMarkdownBuilder()},
                  styleSheet: MarkdownStyleSheet.fromTheme(
                    Theme.of(context),
                  ).copyWith(
                    // h1スタイル
                    h1: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    // h2スタイル
                    h2: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                    // h3スタイル
                    h3: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    // テーブルヘッダースタイル
                    tableHead: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                    // テーブルボーダー
                    tableBorder: TableBorder.all(
                      color: Theme.of(context).dividerColor,
                      width: 0.5,
                    ),
                    // テーブルセルパディング
                    tableCellsPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
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
                    // blockquote スタイル
                    blockquoteDecoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 4,
                        ),
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                ),
    );
  }
}
