import 'dart:math';
import 'dart:typed_data';

/// Frame de sensores de un guante individual
class SensorFrame {
  final double fingers; // Bitmask decodificado (5 bits)
  final double pitch;
  final double roll;
  final double ax, ay, az;
  final double gx, gy, gz;

  SensorFrame({
    required this.fingers,
    required this.pitch,
    required this.roll,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });

  /// Parsea 17 bytes little-endian del guante
  factory SensorFrame.fromBinary(Uint8List data) {
    if (data.length < 17) {
      return SensorFrame(
        fingers: 0, pitch: 0, roll: 0,
        ax: 0, ay: 0, az: 0, gx: 0, gy: 0, gz: 0,
      );
    }

    final byteData = ByteData.sublistView(data);

    // Byte 0: bitmask de dedos
    final mask = data[0];
    double fingers = 0;
    for (int i = 0; i < 5; i++) {
      if ((mask >> i) & 1 == 1) fingers += pow(2, i).toDouble();
    }

    // Bytes 1-16: int16 little-endian
    return SensorFrame(
      fingers: fingers,
      pitch: byteData.getInt16(1, Endian.little) / 100.0,
      roll: byteData.getInt16(3, Endian.little) / 100.0,
      ax: byteData.getInt16(5, Endian.little) / 100.0,
      ay: byteData.getInt16(7, Endian.little) / 100.0,
      az: byteData.getInt16(9, Endian.little) / 100.0,
      gx: byteData.getInt16(11, Endian.little) / 10.0,
      gy: byteData.getInt16(13, Endian.little) / 10.0,
      gz: byteData.getInt16(15, Endian.little) / 10.0,
    );
  }
}

/// Vector bimanual de 26 dimensiones
class BimanualVector {
  final List<double> values;

  BimanualVector(this.values);

  /// Construye desde frames de ambos guantes (null si no conectado)
  factory BimanualVector.fromFrames(SensorFrame? left, SensorFrame? right) {
    final v = <double>[];

    void addHand(SensorFrame? frame) {
      if (frame == null) {
        // 13 ceros para mano desconectada
        v.addAll(List.filled(13, 0.0));
      } else {
        // 5 dedos
        for (int i = 0; i < 5; i++) {
          v.add(((frame.fingers.toInt() >> i) & 1).toDouble());
        }
        // Normalizaciones
        v.add(frame.pitch / 180.0);
        v.add(frame.roll / 180.0);
        v.add(frame.ax / 20.0);
        v.add(frame.ay / 20.0);
        v.add(frame.az / 20.0);
        v.add(frame.gx / 10.0);
        v.add(frame.gy / 10.0);
        v.add(frame.gz / 10.0);
      }
    }

    addHand(left);
    addHand(right);

    return BimanualVector(v);
  }

  double distanceTo(BimanualVector other) {
    double sum = 0;
    for (int i = 0; i < values.length; i++) {
      final d = values[i] - other.values[i];
      sum += d * d;
    }
    return sqrt(sum / values.length);
  }
}

/// Seña guardada
class Gesture {
  final String id;
  final Map<String, String> translations;
  final bool isDynamic;
  final bool useLeft;
  final bool useRight;
  final List<List<double>> samples;     // Para estáticas
  final List<List<List<double>>> sequences; // Para dinámicas

  Gesture({
    required this.id,
    this.translations = const {},
    this.isDynamic = false,
    this.useLeft = true,
    this.useRight = false,
    this.samples = const [],
    this.sequences = const [],
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'translations': translations,
    'isDynamic': isDynamic,
    'useLeft': useLeft,
    'useRight': useRight,
    'samples': samples,
    'sequences': sequences,
  };

  factory Gesture.fromJson(Map<String, dynamic> json) => Gesture(
    id: json['id'] as String,
    translations: Map<String, String>.from(json['translations'] ?? {}),
    isDynamic: json['isDynamic'] as bool? ?? false,
    useLeft: json['useLeft'] as bool? ?? true,
    useRight: json['useRight'] as bool? ?? false,
    samples: (json['samples'] as List?)?.map((e) => (e as List).cast<double>()).toList() ?? [],
    sequences: (json['sequences'] as List?)?.map((e) =>
        (e as List).map((f) => (f as List).cast<double>()).toList()
    ).toList() ?? [],
  );
}

/// Resultado de reconocimiento
class RecognitionResult {
  final String? label;
  final double score;
  final bool isDynamic;

  RecognitionResult({this.label, this.score = 0, this.isDynamic = false});
}

/// Utilidades matemáticas de reconocimiento
class GestureMath {
  /// Reconocimiento estático con KNN (k=3)
  static RecognitionResult recognizeStatic(
    BimanualVector current,
    List<Gesture> gestures, {
    double threshold = 0.60,
    int k = 3,
  }) {
    final staticGestures = gestures.where((g) => !g.isDynamic && g.samples.isNotEmpty);
    if (staticGestures.isEmpty) return RecognitionResult();

    final distances = <_LabeledDistance>[];

    for (final g in staticGestures) {
      for (final sample in g.samples) {
        final sampleVec = BimanualVector(sample);
        final dist = current.distanceTo(sampleVec);
        distances.add(_LabeledDistance(g.id, dist));
      }
    }

    distances.sort((a, b) => a.distance.compareTo(b.distance));
    final topK = distances.take(k).toList();
    final meanDist = topK.map((d) => d.distance).reduce((a, b) => a + b) / topK.length;

    if (meanDist > threshold) return RecognitionResult();

    final label = _mostCommon(topK.map((d) => d.label).toList());
    return RecognitionResult(
      label: label,
      score: (1.0 - meanDist / threshold).clamp(0.0, 1.0),
      isDynamic: false,
    );
  }

  /// Reconocimiento dinámico con DTW
  static RecognitionResult recognizeDynamic(
    List<BimanualVector> sequence,
    List<Gesture> gestures, {
    double threshold = 0.55,
    int k = 3,
  }) {
    final dynamicGestures = gestures.where((g) => g.isDynamic && g.sequences.isNotEmpty);
    if (dynamicGestures.isEmpty) return RecognitionResult();

    final distances = <_LabeledDistance>[];

    for (final g in dynamicGestures) {
      for (final refSeq in g.sequences) {
        final refVectors = refSeq.map((s) => BimanualVector(s)).toList();
        final dist = _dtwDistance(sequence, refVectors);
        distances.add(_LabeledDistance(g.id, dist));
      }
    }

    distances.sort((a, b) => a.distance.compareTo(b.distance));
    final topK = distances.take(k).toList();
    final meanDist = topK.map((d) => d.distance).reduce((a, b) => a + b) / topK.length;

    if (meanDist > threshold) return RecognitionResult();

    return RecognitionResult(
      label: _mostCommon(topK.map((d) => d.label).toList()),
      score: (1.0 - meanDist / threshold).clamp(0.0, 1.0),
      isDynamic: true,
    );
  }

  /// Distancia DTW con banda de Sakoe-Chiba
  static double _dtwDistance(
    List<BimanualVector> a,
    List<BimanualVector> b,
  ) {
    final n = a.length, m = b.length;
    final band = max(20, (0.2 * max(n, m)).round());
    final inf = double.infinity;

    final dtw = List.generate(n + 1, (_) => List.filled(m + 1, inf));
    dtw[0][0] = 0;

    for (int i = 1; i <= n; i++) {
      for (int j = max(1, i - band); j <= min(m, i + band); j++) {
        final cost = a[i - 1].distanceTo(b[j - 1]);
        dtw[i][j] = cost + [
          dtw[i - 1][j],     // inserción
          dtw[i][j - 1],     // deleción
          dtw[i - 1][j - 1], // match
        ].reduce(min);
      }
    }

    return dtw[n][m] / max(n, m);
  }

  static String _mostCommon(List<String> items) {
    final counts = <String, int>{};
    for (final item in items) {
      counts[item] = (counts[item] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
}

class _LabeledDistance {
  final String label;
  final double distance;
  _LabeledDistance(this.label, this.distance);
}

/// Filtro de estabilidad (permanencia de 250-350ms)
class StabilityFilter {
  final int requiredFrames;
  String? _candidate;
  int _count = 0;

  StabilityFilter({this.requiredFrames = 15}); // ~300ms a 50Hz

  /// Devuelve true si la seña se mantuvo estable
  bool update(String? label) {
    if (label == null) {
      _candidate = null;
      _count = 0;
      return false;
    }

    if (label == _candidate) {
      _count++;
      if (_count >= requiredFrames) {
        _count = 0;
        return true;
      }
    } else {
      _candidate = label;
      _count = 1;
    }
    return false;
  }
}

/// Segmentador de movimiento para señas dinámicas
class MotionSegmenter {
  static const double accelMin = 0.80;
  static const double accelMax = 1.20;
  static const int minFrames = 8;
  static const int timeoutMs = 2500;

  bool _recording = false;
  int _stillFrames = 0;
  DateTime? _startTime;
  final List<BimanualVector> _buffer = [];

  /// Procesa un vector y devuelve la secuencia completa si terminó
  List<BimanualVector>? process(BimanualVector vector) {
    // Calcular magnitud de aceleración (índices 7-9 en vector de 13)
    final ax = vector.values[7] * 20.0;
    final ay = vector.values[8] * 20.0;
    final az = vector.values[9] * 20.0;
    final mag = sqrt(ax * ax + ay * ay + az * az);

    final inRest = mag >= accelMin && mag <= accelMax;

    if (!_recording) {
      if (!inRest) {
        // Iniciar grabación
        _recording = true;
        _stillFrames = 0;
        _startTime = DateTime.now();
        _buffer.clear();
        _buffer.add(vector);
      }
    } else {
      _buffer.add(vector);

      if (inRest) {
        _stillFrames++;
        if (_stillFrames >= 8 && _buffer.length >= minFrames) {
          // Terminar grabación
          final result = List<BimanualVector>.from(_buffer);
          _reset();
          return result;
        }
      } else {
        _stillFrames = 0;
      }

      // Timeout
      if (_startTime != null &&
          DateTime.now().difference(_startTime!).inMilliseconds > timeoutMs) {
        _reset();
      }
    }
    return null;
  }

  void _reset() {
    _recording = false;
    _stillFrames = 0;
    _startTime = null;
    _buffer.clear();
  }
}