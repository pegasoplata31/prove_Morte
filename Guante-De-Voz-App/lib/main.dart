import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_manager.dart';
import 'models.dart';
import 'storage.dart';
import 'ai_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestPermissions();
  runApp(const BeyondWordsApp());
}

Future<void> _requestPermissions() async {
  await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.locationWhenInUse,
  ].request();
}

class BeyondWordsApp extends StatelessWidget {
  const BeyondWordsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beyond Words',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A84FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentTab = 0;

  final BleManager _ble = BleManager();
  final FlutterTts _tts = FlutterTts();
  final AiService _ai = AiService();

  final List<SensorFrame?> _leftFrames = [];
  final List<SensorFrame?> _rightFrames = [];
  final List<BimanualVector> _dynamicBuffer = [];

  List<Gesture> _gestures = [];
  Gesture? _recognized;
  double _confidence = 0;
  bool _phraseMode = false;
  final List<String> _phraseWords = [];

  BimanualVector? _restVector;
  final StabilityFilter _stability = StabilityFilter();
  final MotionSegmenter _segmenter = MotionSegmenter();

  String _outputLang = 'es-PA';
  bool _isDarkMode = true;
  double _speechRate = 0.5;
  double _volume = 1.0;

  Timer? _recognizeTimer;

  @override
  void initState() {
    super.initState();
    _initTts();
    _loadData();
    _setupBle();
    _startRecognitionLoop();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage(_outputLang);
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(_volume);
  }

  Future<void> _loadData() async {
    _gestures = await Storage.loadGestures();
    _restVector = await Storage.loadRestVector();
    final settings = await Storage.loadSettings();
    if (mounted) {
      setState(() {
        _outputLang = settings['lang'] ?? 'es-PA';
        _isDarkMode = settings['dark'] ?? true;
        _speechRate = settings['rate'] ?? 0.5;
        _volume = settings['volume'] ?? 1.0;
      });
    }
  }

  void _setupBle() {
    _ble.onFrame = (frame, isLeft) {
      if (!mounted) return;
      setState(() {
        if (isLeft) {
          _leftFrames.add(frame);
          if (_leftFrames.length > 30) _leftFrames.removeAt(0);
        } else {
          _rightFrames.add(frame);
          if (_rightFrames.length > 30) _rightFrames.removeAt(0);
        }
      });
    };

    _ble.onConnectionChanged = (device, connected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${device.platformName} ${connected ? "conectado" : "desconectado"}')),
      );
    };
  }

  void _startRecognitionLoop() {
    _recognizeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _recognizeTick();
    });
  }

  void _recognizeTick() {
    if (_gestures.isEmpty) return;

    final left = _leftFrames.isNotEmpty ? _leftFrames.last : null;
    final right = _rightFrames.isNotEmpty ? _rightFrames.last : null;

    if (left == null && right == null) return;

    final vector = BimanualVector.fromFrames(left, right);

    // Verificar distancia de reposo
    if (_restVector != null) {
      final restDist = vector.distanceTo(_restVector!);
      if (restDist < 0.30) {
        _stability.update(null);
        return;
      }
    }

    // Reconocimiento estático
    final result = GestureMath.recognizeStatic(vector, _gestures);

    // Verificar estabilidad
    if (result.label != null && _stability.update(result.label)) {
      _acceptWord(result.label!, result.score);
    }

    // Segmentación dinámica
    final sequence = _segmenter.process(vector);
    if (sequence != null && sequence.length >= 8) {
      final dynResult = GestureMath.recognizeDynamic(sequence, _gestures);
      if (dynResult.label != null) {
        _acceptWord(dynResult.label!, dynResult.score);
      }
    }
  }

  void _acceptWord(String label, double score) {
    if (!mounted) return;
    setState(() {
      _recognized = _gestures.firstWhere((g) => g.id == label, orElse: () => Gesture(id: label));
      _confidence = score;
    });

    if (_phraseMode) {
      setState(() => _phraseWords.add(label));
    } else {
      _speak(label);
    }
  }

  Future<void> _speak(String text) async {
    // Buscar traducción
    final gesture = _gestures.firstWhere(
      (g) => g.id == text,
      orElse: () => Gesture(id: text),
    );
    final translated = gesture.translations[_outputLang] ?? text;

    await _tts.setLanguage(_outputLang);
    await _tts.speak(translated);
  }

  Future<void> _speakPhrase() async {
    if (_phraseWords.isEmpty) return;

    final corrected = await _ai.fixGrammar(_phraseWords);
    await _tts.setLanguage(_outputLang);
    await _tts.speak(corrected);
  }

  @override
  void dispose() {
    _recognizeTimer?.cancel();
    _ble.disconnectAll();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Beyond Words'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth),
            onPressed: () => _ble.scanAndConnect(),
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: IndexedStack(
        index: _currentTab,
        children: [
          _buildTranslatePage(),
          _buildAddSignPage(),
          _buildSignsListPage(),
          _buildBlePage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (i) => setState(() => _currentTab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.translate), label: 'Traducir'),
          NavigationDestination(icon: Icon(Icons.add), label: 'Agregar'),
          NavigationDestination(icon: Icon(Icons.list), label: 'Señas'),
          NavigationDestination(icon: Icon(Icons.bluetooth), label: 'BLE'),
        ],
      ),
    );
  }

  Widget _buildTranslatePage() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Indicador de confianza
          SizedBox(
            height: 120,
            child: CustomPaint(
              painter: _PulsePainter(confidence: _confidence),
              child: Center(
                child: Text(
                  '${(_confidence * 100).toInt()}%',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Palabra reconocida
          Text(
            _recognized?.id ?? '---',
            style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),

          // Selector de idioma
          DropdownButton<String>(
            value: _outputLang,
            items: const [
              DropdownMenuItem(value: 'es-PA', child: Text('Español (Panamá)')),
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'pt', child: Text('Português')),
            ],
            onChanged: (v) => setState(() => _outputLang = v!),
          ),
          const SizedBox(height: 16),

          // Modo Frase
          SwitchListTile(
            title: const Text('Modo Frase'),
            value: _phraseMode,
            onChanged: (v) => setState(() => _phraseMode = v),
          ),

          if (_phraseMode) ...[
            Text(_phraseWords.join(' · '), style: const TextStyle(fontSize: 18)),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _speakPhrase,
                  child: const Text('Reproducir frase'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => setState(() => _phraseWords.clear()),
                  child: const Text('Limpiar'),
                ),
              ],
            ),
          ],

          const Spacer(),

          // Botón reproducir
          ElevatedButton.icon(
            onPressed: _recognized != null ? () => _speak(_recognized!.id) : null,
            icon: const Icon(Icons.volume_up),
            label: const Text('Reproducir voz'),
          ),
        ],
      ),
    );
  }

  Widget _buildAddSignPage() {
    return const Center(child: Text('Agregar Señas\n(Implementación completa en documento)'));
  }

  Widget _buildSignsListPage() {
    return ListView.builder(
      itemCount: _gestures.length,
      itemBuilder: (context, i) {
        final g = _gestures[i];
        return ListTile(
          title: Text(g.id),
          subtitle: Text('${g.isDynamic ? "Dinámica" : "Estática"} · ${g.samples.length} muestras'),
          trailing: IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              setState(() => _gestures.removeAt(i));
              Storage.saveGestures(_gestures);
            },
          ),
        );
      },
    );
  }

  Widget _buildBlePage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: () => _ble.scanAndConnect(),
            child: const Text('Buscar y conectar guantes'),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => _ble.disconnectAll(),
            child: const Text('Desconectar todo'),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        children: [
          SwitchListTile(
            title: const Text('Modo oscuro'),
            value: _isDarkMode,
            onChanged: (v) => setState(() => _isDarkMode = v),
          ),
          ListTile(
            title: const Text('Velocidad de voz'),
            subtitle: Slider(
              value: _speechRate,
              min: 0.25,
              max: 0.70,
              onChanged: (v) {
                setState(() => _speechRate = v);
                _tts.setSpeechRate(v);
              },
            ),
          ),
          ListTile(
            title: const Text('Volumen'),
            subtitle: Slider(
              value: _volume,
              min: 0,
              max: 1,
              onChanged: (v) {
                setState(() => _volume = v);
                _tts.setVolume(v);
              },
            ),
          ),
          ListTile(
            title: const Text('Guardar postura de reposo'),
            onTap: () {
              final left = _leftFrames.isNotEmpty ? _leftFrames.last : null;
              final right = _rightFrames.isNotEmpty ? _rightFrames.last : null;
              if (left != null || right != null) {
                final vec = BimanualVector.fromFrames(left, right);
                Storage.saveRestVector(vec);
                setState(() => _restVector = vec);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Postura de reposo guardada')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Painter para indicador circular de confianza
class _PulsePainter extends CustomPainter {
  final double confidence;

  _PulsePainter({required this.confidence});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 4;

    // Círculo de fondo
    final bgPaint = Paint()
      ..color = Colors.white10
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;

    canvas.drawCircle(center, radius, bgPaint);

    // Arco de confianza
    final fgPaint = Paint()
      ..color = Color.lerp(Colors.cyan, Colors.green, confidence)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.14159 / 2,
      2 * 3.14159 * confidence,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _PulsePainter oldDelegate) {
    return oldDelegate.confidence != confidence;
  }
}