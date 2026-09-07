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
// Root Maps: キーボードショートカットハンドラー
// Deleteキーなどのグローバルキーボードイベントを処理

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../providers/notification_providers.dart';
import '../providers/selection_providers.dart';
import '../providers/ui_state_providers.dart';

/// キーボードイベントハンドラー
/// グローバルなキーボードショートカットを管理
class KeyboardHandler {
  /// テキスト入力フィールドにフォーカスがあるかチェック
  /// ダイアログ内のTextField、属性テーブル編集など
  static bool _isTextInputFocused(BuildContext context, WidgetRef ref) {
    if (ref.read(isAttributeTableEditingProvider)) {
      return true;
    }

    // 現在のフォーカスノードをチェック
    final focusNode = FocusManager.instance.primaryFocus;
    if (focusNode == null) {
      return false;
    }

    // デバッグ名にEditableTextが含まれているかチェック（IME切り替え時にも安定）
    final debugLabel = focusNode.debugLabel ?? '';
    if (debugLabel.contains('EditableText') || debugLabel.contains('TextField')) {
      return true;
    }

    // フォーカスノードのコンテキストからEditableTextを探す
    // TextField, TextFormField, EditableText等にフォーカスがある場合はtrue
    final focusContext = focusNode.context;
    if (focusContext != null) {
      // EditableTextStateを探す（TextField内部で使用される）
      final editableText =
          focusContext.findAncestorStateOfType<EditableTextState>();
      if (editableText != null) {
        return true;
      }
      
      // 親ウィジェットツリーにTextFieldやTextFormFieldがあるか確認
      // （CapsLock押下時のフォールバック）
      bool hasTextField = false;
      focusContext.visitAncestorElements((element) {
        final widget = element.widget;
        if (widget is TextField || widget is TextFormField || widget is EditableText) {
          hasTextField = true;
          return false; // 探索終了
        }
        return true; // 探索継続
      });
      if (hasTextField) {
        return true;
      }
    }

    return false;
  }

  /// Deleteキー押下時の処理
  /// 選択されたフィーチャを削除
  static Future<void> handleDeleteKey(
    BuildContext context,
    dynamic mapState,
    WidgetRef ref,
  ) async {
    AppLogger.debug('[KeyboardHandler] Deleteキーが押されました');

    final selectedFeatures = ref.read(selectedFeaturesProvider);
    if (selectedFeatures.isEmpty) {
      AppLogger.debug('[KeyboardHandler] 削除対象のフィーチャが選択されていません');
      return;
    }

    final featureCount = selectedFeatures.length;
    AppLogger.debug('[KeyboardHandler] 削除対象: $featureCount個のフィーチャ');

    try {
      await ref.read(selectedFeaturesProvider.notifier).disposeSelectedFeatures();

      AppLogger.debug('[KeyboardHandler] フィーチャ削除完了: $featureCount個');

      ref.read(notificationCenterProvider.notifier).add(
        title: '$featureCount個のフィーチャを削除しました',
        level: NotificationLevel.success,
      );
    } catch (e) {
      AppLogger.debug('[KeyboardHandler] フィーチャ削除エラー: $e');

      ref.read(notificationCenterProvider.notifier).add(
        title: t.editor.deleteFeatureError(error: e.toString()),
        level: NotificationLevel.error,
      );
    }
  }

  /// キーイベントを処理
  /// 戻り値: trueの場合、イベントが処理された（伝播を停止）
  static Future<bool> handleKeyEvent(
    KeyEvent event,
    BuildContext context,
    dynamic mapState,
    WidgetRef ref,
  ) async {
    // キーが押された時のみ処理（リリースイベントは無視）
    if (event is! KeyDownEvent) {
      return false;
    }

    // 修飾キー（CapsLock, Shift, Ctrl, Alt等）は無視
    // IME切り替え時にこれらのキーが押されると、フォーカス判定が不安定になるため
    final modifierKeys = {
      LogicalKeyboardKey.capsLock,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
      LogicalKeyboardKey.numLock,
      LogicalKeyboardKey.scrollLock,
      // IME関連キー
      LogicalKeyboardKey.convert,
      LogicalKeyboardKey.nonConvert,
      LogicalKeyboardKey.kanaMode,
      LogicalKeyboardKey.hiragana,
      LogicalKeyboardKey.katakana,
      LogicalKeyboardKey.hiraganaKatakana,
      LogicalKeyboardKey.zenkakuHankaku,
      LogicalKeyboardKey.hankaku,
      LogicalKeyboardKey.zenkaku,
    };
    if (modifierKeys.contains(event.logicalKey)) {
      return false;
    }

    // IME関連の無効なキーイベントを安全にフィルタリング
    // Windows日本語入力との互換性のため、以下のケースを無視:
    // 1. 無効な物理キーID（IMEからの合成イベント）
    // 2. 極端に大きいUSB HID使用コード
    try {
      final physicalKeyId = event.physicalKey.usbHidUsage;
      if (physicalKeyId > 0x100000000 || physicalKeyId == 0) {
        // 無効なキーIDは静かに無視
        return false;
      }
    } catch (e) {
      // 物理キー情報の取得に失敗した場合も無視
      return false;
    }

    // テキスト入力中は全てのショートカットを無視
    // CapsLock押下直後もEditableTextのフォーカスは維持されているはずなので、
    // この判定を先に行う
    if (_isTextInputFocused(context, ref)) {
      return false; // イベントを伝播させる（TextFieldで処理される）
    }

    AppLogger.debug('[KeyboardHandler] キー押下: ${event.logicalKey}');

    // Deleteキーまたはバックスペースキー
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      await handleDeleteKey(context, mapState, ref);
      return true; // イベントを処理済みとしてマーク
    }

    // 将来的な拡張用コメント
    // Ctrl+Z: Undo
    // Ctrl+Y: Redo
    // Ctrl+C: Copy
    // Ctrl+V: Paste
    // Ctrl+A: Select All
    // Esc: Cancel current operation

    return false; // イベント未処理
  }
}

/// キーボードショートカットを有効にするウィジェット
/// マップページ全体をラップして使用
/// 
/// HardwareKeyboardのハンドラーを直接使用して、
/// IME関連のキーイベント不整合問題を回避
class KeyboardShortcutWrapper extends ConsumerStatefulWidget {
  final Widget child;
  final dynamic mapState;

  const KeyboardShortcutWrapper({
    super.key,
    required this.child,
    required this.mapState,
  });

  @override
  ConsumerState<KeyboardShortcutWrapper> createState() =>
      _KeyboardShortcutWrapperState();
}

class _KeyboardShortcutWrapperState extends ConsumerState<KeyboardShortcutWrapper> {
  bool _handleKeyEvent(KeyEvent event) {
    // IME関連の無効なキーイベントを早期にフィルタリング
    // Windows日本語入力で発生する不正なキーイベントを除外
    try {
      final physicalKeyId = event.physicalKey.usbHidUsage;
      // 無効な物理キーID（0x1600000000等のIME合成イベント）
      if (physicalKeyId > 0x100000000 || physicalKeyId == 0) {
        AppLogger.debug('[Root Maps] IME関連キーボードイベントを無視');
        return false; // イベントを伝播
      }
    } catch (e) {
      // 物理キー情報の取得に失敗した場合も無視
      return false;
    }

    // contextが利用可能な場合のみ処理
    if (!mounted) return false;

    // 非同期で処理（UIをブロックしない）
    KeyboardHandler.handleKeyEvent(event, context, widget.mapState, ref).then((
      handled,
    ) {
      if (handled) {
        AppLogger.debug('[KeyboardShortcutWrapper] キーイベント処理済み');
      }
    }).catchError((e) {
      // エラーを静かに無視（IME関連の問題）
      AppLogger.debug('[KeyboardShortcutWrapper] キーイベント処理エラー: $e');
    });

    // イベントを常に伝播させる（他のウィジェットがキーを受け取れるように）
    return false;
  }

  @override
  void initState() {
    super.initState();
    // HardwareKeyboardにハンドラーを登録
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    // ハンドラーを解除
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
