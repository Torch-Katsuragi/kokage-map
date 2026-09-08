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
/// web には isolate が無いので、その場で実行する（`terrain_worker_io.dart` と同じ顔）
class TerrainWorker {
  TerrainWorker({this.size = 2});

  static final TerrainWorker instance = TerrainWorker();

  final int size;

  Future<R> run<Q, R>(R Function(Q) fn, Q arg) async => fn(arg);

  int get pending => 0;

  void dispose() {}
}
