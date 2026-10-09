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
part of 'terrain_map_layer.dart';

/// 地図の上の丸いボタン（拡大・縮小・ドライブ）
class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white.withValues(alpha: 0.9),
          shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 22)),
          ),
        ),
      );
}

/// 方位に合わせて回るコンパス = **2D / 3D の切替の入り口**（ユーザー 2026-09-13「移動じゃなくてモード変更の入り口に」）。
/// タップで 2D（真上固定）⇄ 3D、ダブルタップで北を上に、長押しで眺めモード（透視。3D のときだけ、透視中は縁が空色）。
/// 3D で傾いていれば縁を少し濃くする。下に今のモードを小さく書く
class _CompassButton extends StatelessWidget {
  const _CompassButton({
    super.key,
    required this.bearingDeg,
    required this.pitchDeg,
    required this.flat,
    required this.onPressed,
    required this.onDoubleTap,
    this.perspective = false,
    this.onLongPress,
  });

  final double bearingDeg;
  final double pitchDeg;

  /// 2D（真上固定）か
  final bool flat;
  final bool perspective;
  final VoidCallback onPressed;
  final VoidCallback onDoubleTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: t.map.terrain.compassTip,
        child: Material(
          color: perspective ? const Color(0xFFDDEBF8) : Colors.white.withValues(alpha: 0.9),
          shape: CircleBorder(
            side: BorderSide(
              color: perspective ? Colors.lightBlue : (pitchDeg > 1 ? Colors.blueGrey : Colors.black26),
              width: pitchDeg > 1 || perspective ? 2 : 1,
            ),
          ),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            onDoubleTap: onDoubleTap,
            onLongPress: onLongPress,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Transform.translate(
                    offset: const Offset(0, -3),
                    child: Transform.rotate(
                      angle: -bearingDeg * math.pi / 180,
                      child: const Icon(Icons.navigation, size: 22, color: Colors.redAccent),
                    ),
                  ),
                  Positioned(
                    bottom: 3,
                    child: Text(
                      flat ? '2D' : '3D',
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: flat ? Colors.black54 : Colors.blueGrey, height: 1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
