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

import 'dart:io';
import 'dart:typed_data';

import 'ntrip_socket.dart';

class _IoNtripSocket implements NtripSocket {
  _IoNtripSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  void write(List<int> bytes) {
    _socket.add(bytes);
  }

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
    try {
      _socket.destroy();
    } catch (_) {}
  }
}

Future<NtripSocket> connectPlatformNtripSocket(
  String host,
  int port, {
  required bool useTls,
  required Duration timeout,
}) async {
  final Socket socket = useTls
      ? await SecureSocket.connect(host, port, timeout: timeout)
      : await Socket.connect(host, port, timeout: timeout);
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
  return _IoNtripSocket(socket);
}
