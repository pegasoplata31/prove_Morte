import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'models.dart';

/// Gestor de conexión BLE para los guantes Beyond Words
class BleManager {
  static final BleManager _instance = BleManager._();
  factory BleManager() => _instance;
  BleManager._();

  // UUIDs según especificación
  static final Guid serviceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
  static final Guid characteristicUuid = Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');

  // Nombres de dispositivos
  static const String leftGloveName = 'Beyondwords_Left';
  static const String rightGloveName = 'Beyondwords_Right';

  BluetoothDevice? _leftDevice;
  BluetoothDevice? _rightDevice;

  StreamSubscription<List<int>>? _leftSub;
  StreamSubscription<List<int>>? _rightSub;

  /// Callback cuando llega un frame
  void Function(SensorFrame frame, bool isLeft)? onFrame;

  /// Callback cuando se conecta/desconecta
  void Function(BluetoothDevice device, bool connected)? onConnectionChanged;

  BluetoothDevice? get leftDevice => _leftDevice;
  BluetoothDevice? get rightDevice => _rightDevice;

  bool get isLeftConnected => _leftDevice != null;
  bool get isRightConnected => _rightDevice != null;

  /// Inicia escaneo y conexión automática a los guantes
  Future<void> scanAndConnect() async {
    await stopScan();
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

    FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName;
        if (name == leftGloveName && _leftDevice == null) {
          _connectToDevice(r.device, isLeft: true);
        } else if (name == rightGloveName && _rightDevice == null) {
          _connectToDevice(r.device, isLeft: false);
        }
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device, {required bool isLeft}) async {
    try {
      await device.connect(timeout: const Duration(seconds: 10));
      await device.discoverServices();

      if (isLeft) {
        _leftDevice = device;
        _subscribeToNotifications(device, isLeft: true);
      } else {
        _rightDevice = device;
        _subscribeToNotifications(device, isLeft: false);
      }

      onConnectionChanged?.call(device, true);

      // Escuchar desconexión
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          onConnectionChanged?.call(device, false);
          if (isLeft) {
            _leftDevice = null;
            _leftSub?.cancel();
          } else {
            _rightDevice = null;
            _rightSub?.cancel();
          }
        }
      });
    } catch (e) {
      debugPrint('Error conectando a ${device.platformName}: $e');
    }
  }

  void _subscribeToNotifications(BluetoothDevice device, {required bool isLeft}) {
    for (final service in device.servicesList) {
      if (service.uuid == serviceUuid) {
        for (final char in service.characteristics) {
          if (char.uuid == characteristicUuid) {
            char.setNotifyValue(true);
            final sub = char.onValueReceived.listen((data) {
              if (data.length >= 17) {
                final frame = SensorFrame.fromBinary(Uint8List.fromList(data));
                onFrame?.call(frame, isLeft);
              }
            });

            if (isLeft) {
              _leftSub = sub;
            } else {
              _rightSub = sub;
            }
          }
        }
      }
    }
  }

  /// Envía comando de calibración a ambos guantes
  Future<void> sendCalibrationCommand() async {
    for (final device in [_leftDevice, _rightDevice]) {
      if (device == null) continue;
      for (final service in device.servicesList) {
        if (service.uuid == serviceUuid) {
          for (final char in service.characteristics) {
            if (char.uuid == characteristicUuid) {
              await char.write([0x43, 0x41, 0x4C, 0x49, 0x42]); // "CALIB"
            }
          }
        }
      }
    }
  }

  Future<void> disconnectAll() async {
    await _leftSub?.cancel();
    await _rightSub?.cancel();
    await _leftDevice?.disconnect();
    await _rightDevice?.disconnect();
    _leftDevice = null;
    _rightDevice = null;
  }

  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
  }
}