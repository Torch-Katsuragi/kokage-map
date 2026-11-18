package io.github.edufolly.flutterbluetoothserial;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Arrays;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothSocket;

/// Universal Bluetooth serial connection class (for Java)
public abstract class BluetoothConnection
{
    protected static final UUID DEFAULT_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");

    protected BluetoothAdapter bluetoothAdapter;

    protected volatile ConnectionThread connectionThread = null;

    public boolean isConnected() {
        ConnectionThread thread = connectionThread;
        return thread != null && !thread.requestedClosing;
    }

    public BluetoothConnection(BluetoothAdapter bluetoothAdapter) {
        this.bluetoothAdapter = bluetoothAdapter;
    }

    /// Connects to given device by hardware address
    public void connect(String address, UUID uuid) throws IOException {
        if (isConnected()) {
            throw new IOException("already connected");
        }

        BluetoothDevice device = bluetoothAdapter.getRemoteDevice(address);
        if (device == null) {
            throw new IOException("device not found");
        }

        BluetoothSocket socket = device.createRfcommSocketToServiceRecord(uuid);
        if (socket == null) {
            throw new IOException("socket connection not established");
        }

        // Only cancel discovery if actually discovering, avoiding spurious HCI Inquiry_Cancel
        // commands that disturb other active Bluetooth Classic / BLE links on the 2.4GHz radio.
        try {
            if (bluetoothAdapter.isDiscovering()) {
                bluetoothAdapter.cancelDiscovery();
            }
        } catch (SecurityException ignored) {
        }

        try {
            socket.connect();
        } catch (IOException connectEx) {
            // Release allocated RFCOMM port / native fd immediately on failed connect
            try {
                socket.close();
            } catch (Exception ignored) {
            }
            throw connectEx;
        }

        ConnectionThread thread = new ConnectionThread(socket);
        connectionThread = thread;
        thread.start();
    }

    /// Connects to given device by hardware address (default UUID used)
    public void connect(String address) throws IOException {
        connect(address, DEFAULT_UUID);
    }

    /// Disconnects current session (ignore if not connected)
    public void disconnect() {
        ConnectionThread thread = connectionThread;
        connectionThread = null;
        if (thread != null) {
            thread.cancel();
        }
    }

    /// Writes to connected remote device
    public void write(byte[] data) throws IOException {
        ConnectionThread thread = connectionThread;
        if (thread == null || thread.requestedClosing) {
            throw new IOException("not connected");
        }

        thread.write(data);
    }

    /// Callback for reading data.
    protected abstract void onRead(byte[] data);

    /// Callback for disconnection.
    protected abstract void onDisconnected(boolean byRemote);

    /// Thread to handle connection I/O
    private class ConnectionThread extends Thread {
        private final BluetoothSocket socket;
        private final InputStream input;
        private final OutputStream output;
        private volatile boolean requestedClosing = false;
        private final AtomicBoolean socketClosed = new AtomicBoolean(false);

        ConnectionThread(BluetoothSocket socket) {
            super(" KokageBtReader");
            this.socket = socket;
            InputStream tmpIn = null;
            OutputStream tmpOut = null;

            try {
                tmpIn = socket.getInputStream();
                tmpOut = socket.getOutputStream();
            } catch (IOException e) {
                e.printStackTrace();
            }

            this.input = tmpIn;
            this.output = tmpOut;
        }

        private void closeSocketOnce() {
            if (!socketClosed.compareAndSet(false, true)) {
                return;
            }
            if (output != null) {
                try {
                    output.close();
                } catch (Exception ignored) {
                }
            }
            if (input != null) {
                try {
                    input.close();
                } catch (Exception ignored) {
                }
            }
            if (socket != null) {
                try {
                    socket.close();
                } catch (Exception ignored) {
                }
            }
        }

        /// Thread main code
        @Override
        public void run() {
            byte[] buffer = new byte[1024];
            int bytes;

            try {
                if (input == null) {
                    throw new IOException("Bluetooth input stream unavailable");
                }
                while (!requestedClosing) {
                    bytes = input.read(buffer);
                    if (bytes < 0) {
                        // EOF from remote peer
                        break;
                    }
                    if (bytes > 0) {
                        onRead(Arrays.copyOf(buffer, bytes));
                    }
                }
            } catch (Exception e) {
                // `input.read` throws IOException when closed by remote device or local cancel()
            } finally {
                boolean byRemote = !requestedClosing;
                requestedClosing = true;
                if (connectionThread == this) {
                    connectionThread = null;
                }
                // Always close BluetoothSocket even on remote disconnect so Bluedroid releases the RFCOMM slot
                closeSocketOnce();
                onDisconnected(byRemote);
            }
        }

        /// Writes to output stream
        public void write(byte[] bytes) throws IOException {
            if (output == null || requestedClosing) {
                throw new IOException("not connected");
            }
            output.write(bytes);
        }

        /// Stops the thread, disconnects
        public void cancel() {
            requestedClosing = true;

            if (output != null) {
                try {
                    output.flush();
                } catch (Exception ignored) {
                }
            }

            try {
                Thread.sleep(50);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }

            closeSocketOnce();
        }
    }
}
