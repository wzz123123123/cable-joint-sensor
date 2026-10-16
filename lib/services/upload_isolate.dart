import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'rs485_protocol.dart';

double _asDouble(dynamic v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  return fallback;
}

double _innerTemp(double xi, double x0i, double xia, double k1, double k2) {
  if (xi == -999) return -999;
  if (xi < x0i) return xi;
  final dEnv = xi - x0i;
  final dAvg = xi - xia;
  return xi + k1 * (dEnv < 0 ? 0 : dEnv) + k2 * (dAvg < 0 ? 0 : dAvg);
}

double _ln(double x) {
  if (x <= 0) return 0;
  if (x == 1) return 0;
  if (x > 2) return 0.693147 + _ln(x / 2);
  var result = 0.0;
  var term = x - 1;
  var power = term;
  for (var i = 1; i <= 20; i++) {
    result += power / i;
    power *= -term;
  }
  return result;
}

double _smoke(double xStar, double a, double t) {
  final tSafe = t == 0 ? 568.0 : t;
  final delta = xStar - a;
  if (delta <= 0) return 0;
  final x0 = 568.0 * (delta / tSafe);
  final m = x0 < 568
      ? -0.00000015 * x0 * x0 + 0.0007 * x0
      : 0.2772 * _ln(x0) - 1.408;
  return m < 0 ? 0 : m;
}

Map<String, dynamic> _displayFromMap(Map snap, Map settings) {
  final upperCorr = _asDouble(settings['upperTempCorrection']);
  final middleCorr = _asDouble(settings['envTempCorrection']);
  final lowerCorr = _asDouble(settings['lowerTempCorrection']);
  final humidityCorr = _asDouble(settings['humidityCorrection']);
  final pt100Corrections = (settings['pt100Corrections'] as List?) ?? const [];
  var corrected = <double>[];
  final ptRaw = snap['pt100_temperatures'];
  if (ptRaw is String && ptRaw.isNotEmpty) {
    try {
      final temps = jsonDecode(ptRaw) as List;
      corrected = List<double>.generate(temps.length, (i) {
        final base = _asDouble(temps[i], -999);
        if (base == -999) return -999;
        final delta = i < pt100Corrections.length ? _asDouble(pt100Corrections[i]) : 0.0;
        return base + delta;
      });
    } catch (_) {}
  }
  final envBase = _asDouble(snap['temperature'], 25);
  var upperTemp = envBase + upperCorr;
  var middleTemp = envBase + middleCorr;
  var lowerTemp = envBase + lowerCorr;
  final nodeId = snap['node_id'] as int? ?? 0;
  if (nodeId == 1 && corrected.length >= 11) {
    upperTemp = corrected[10] + upperCorr;
  } else if (corrected.length >= 10) {
    upperTemp = corrected[9] + upperCorr;
  }
  if (corrected.length >= 12 && corrected[11] != -999) {
    middleTemp = corrected[11] + middleCorr;
  }
  var cable18 = List<double>.filled(18, -999);
  if (corrected.length >= 9) {
    final aK1 = _asDouble(settings['aK1'], 6.42);
    final aK2 = _asDouble(settings['aK2'], 2.5);
    final bK1 = _asDouble(settings['bK1'], 6.42);
    final bK2 = _asDouble(settings['bK2'], 2.5);
    final cK1 = _asDouble(settings['cK1'], 6.42);
    final cK2 = _asDouble(settings['cK2'], 2.5);
    final aL = corrected[0], aM = corrected[1], aR = corrected[2];
    final bL = corrected[3], bM = corrected[4], bR = corrected[5];
    final cL = corrected[6], cM = corrected[7], cR = corrected[8];
    final leftAvg = (aL + bL + cL) / 3;
    final midAvg = (aM + bM + cM) / 3;
    final rightAvg = (aR + bR + cR) / 3;
    cable18 = [
      aL, _innerTemp(aL, upperTemp, leftAvg, aK1, aK2),
      aM, _innerTemp(aM, upperTemp, midAvg, aK1, aK2),
      aR, _innerTemp(aR, upperTemp, rightAvg, aK1, aK2),
      bL, _innerTemp(bL, middleTemp, leftAvg, bK1, bK2),
      bM, _innerTemp(bM, middleTemp, midAvg, bK1, bK2),
      bR, _innerTemp(bR, middleTemp, rightAvg, bK1, bK2),
      cL, _innerTemp(cL, lowerTemp, leftAvg, cK1, cK2),
      cM, _innerTemp(cM, lowerTemp, midAvg, cK1, cK2),
      cR, _innerTemp(cR, lowerTemp, rightAvg, cK1, cK2),
    ];
  }
  var white = 0.1, black = 0.1;
  if (snap['smoke_channel_a'] != null) {
    white = _smoke(_asDouble(snap['smoke_channel_a']), _asDouble(snap['smoke_calib_a']), _asDouble(snap['smoke_thresh_a'], 568));
  }
  if (snap['smoke_channel_b'] != null) {
    black = _smoke(_asDouble(snap['smoke_channel_b']), _asDouble(snap['smoke_calib_b']), _asDouble(snap['smoke_thresh_b'], 568));
  }
  double? humidity;
  if (snap['humidity'] != null) {
    humidity = (_asDouble(snap['humidity']) + humidityCorr).clamp(0, 100).toDouble();
  }
  double? co;
  if (snap['co_ppm'] != null) {
    final raw = _asDouble(snap['co_ppm']);
    co = (raw < 0 || raw > 10000) ? 0.0 : raw;
  }
  return {
    'upperTemp': upperTemp,
    'middleTemp': middleTemp,
    'lowerTemp': lowerTemp,
    'humidity': humidity,
    'pressure': snap['pressure_kpa'],
    'h2': snap['h2_percentage'],
    'co': co,
    'whiteSmoke': white,
    'blackSmoke': black,
    'cableTemps18': cable18,
  };
}

int _crc16(List<int> data) {
  var crc = 0xFFFF;
  for (final b in data) {
    crc ^= b;
    for (var j = 0; j < 8; j++) {
      crc = (crc & 0x0001) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc & 0xFFFF;
}

@pragma('vm:entry-point')
void uploadIsolateMain(SendPort mainPort) {
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  final settingsByNode = <int, Map<String, dynamic>>{};
  final latest = <int, Map<String, dynamic>>{};
  var busy = false;
  Socket? socket;
  var connected = false;
  var txId = 1;

  Future<bool> ensureSocket() async {
    if (socket != null && connected) return true;
    try {
      socket?.destroy();
      socket = await Socket.connect('192.168.201.203', 502, timeout: const Duration(seconds: 2));
      connected = true;
      return true;
    } catch (_) {
      connected = false;
      socket = null;
      return false;
    }
  }

  Future<void> writeModbus(List<int> rs485, int unitId) async {
    if (!await ensureSocket()) return;
    txId = txId >= 0xFFFF ? 1 : txId + 1;
    final mbapLen = 2 + rs485.length;
    final frame = Uint8List(6 + mbapLen);
    frame[0] = (txId >> 8) & 0xFF;
    frame[1] = txId & 0xFF;
    frame[4] = (mbapLen >> 8) & 0xFF;
    frame[5] = mbapLen & 0xFF;
    frame[6] = unitId.clamp(1, 9);
    frame[7] = 0x10;
    for (var i = 0; i < rs485.length; i++) {
      frame[8 + i] = rs485[i];
    }
    try {
      socket!.add(frame);
      await socket!.flush();
    } catch (_) {
      connected = false;
      socket?.destroy();
      socket = null;
    }
  }

  Future<void> drain() async {
    if (busy) return;
    busy = true;
    try {
      while (latest.isNotEmpty) {
        final nodeId = latest.keys.first;
        final snap = latest.remove(nodeId);
        if (snap == null) continue;
        try {
          final settings = settingsByNode[nodeId] ?? const <String, dynamic>{};
          final display = _displayFromMap(snap, settings);
          final cableTemps = (display['cableTemps18'] as List).cast<num>();
          final hasPt100 = snap['pt100_temperatures'] != null &&
              cableTemps.any((t) => t.toDouble() != -999.0);
          if (hasPt100) {
            final payload = <int>[];
            for (final t in cableTemps) {
              payload.addAll(RS485Protocol.encodeTemp100(t.toDouble()));
            }
            await writeModbus(
              RS485Protocol.createRS485Frame(
                nodeId: nodeId,
                sensorId: RS485Protocol.SENSOR_CABLE_TEMP,
                data: payload,
                calculateCRC16: _crc16,
              ),
              nodeId,
            );
          }
          final env = <int>[];
          env.addAll(RS485Protocol.encodeTemp100(_asDouble(display['upperTemp'])));
          env.addAll(RS485Protocol.encodeTemp100(_asDouble(display['middleTemp'])));
          env.addAll(RS485Protocol.encodeTemp100(_asDouble(display['lowerTemp'])));
          env.addAll(RS485Protocol.floatTo2Bytes(_asDouble(display['humidity'])));
          env.addAll(RS485Protocol.floatTo2Bytes(_asDouble(display['pressure'])));
          env.addAll(RS485Protocol.encodeSmoke1000(_asDouble(display['whiteSmoke'])));
          env.addAll(RS485Protocol.encodeSmoke1000(_asDouble(display['blackSmoke'])));
          env.add(_asDouble(display['h2']).round().clamp(0, 255));
          env.addAll(RS485Protocol.intTo2Bytes(_asDouble(display['co']).round().clamp(0, 65535)));
          env.add((_asDouble(snap['smoke_status']).round()) & 0xFF);
          var ext = (_asDouble(snap['smoke_external_temp_c']) * 100).round();
          if (ext < 0) ext += 65536;
          env.add(ext & 0xFF);
          env.add((ext >> 8) & 0xFF);
          await writeModbus(
            RS485Protocol.createRS485Frame(
              nodeId: nodeId,
              sensorId: RS485Protocol.SENSOR_ENV_PARAMS,
              data: env,
              calculateCRC16: _crc16,
            ),
            nodeId,
          );
        } catch (_) {}
      }
    } finally {
      busy = false;
      if (latest.isNotEmpty) unawaited(drain());
    }
  }

  inbox.listen((msg) {
    if (msg is! Map) return;
    final cmd = msg['cmd'];
    if (cmd == 'stop') {
      socket?.destroy();
      inbox.close();
      return;
    }
    if (cmd == 'settings') {
      final id = msg['nodeId'] as int?;
      final s = msg['settings'];
      if (id != null && s is Map) settingsByNode[id] = Map<String, dynamic>.from(s);
      return;
    }
    if (cmd == 'upload') {
      final snap = msg['snapshot'];
      if (snap is! Map) return;
      final map = Map<String, dynamic>.from(snap);
      final nodeId = map['node_id'] as int? ?? 0;
      if (nodeId < 1) return;
      final s = msg['settings'];
      if (s is Map) settingsByNode[nodeId] = Map<String, dynamic>.from(s);
      latest[nodeId] = map;
      unawaited(drain());
    }
  });
}
