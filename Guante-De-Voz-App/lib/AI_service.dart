import 'package:flutter/foundation.dart';

/// Servicio de IA local para corrección gramatical con Gemma 3 1B
/// 
/// NOTA: La integración completa con flutter_gemma requiere configuración
/// adicional. Esta es una versión simplificada que degrada graciosamente.
/// 
/// Para integración completa, consultar la documentación de flutter_gemma:
/// https://pub.dev/packages/flutter_gemma
class AiService {
  bool _isReady = false;
  bool _isInitializing = false;

  bool get isReady => _isReady;

  /// Inicializa el modelo de IA (descarga diferida)
  /// 
  /// En producción, esto descarga el modelo desde Hugging Face.
  /// Por ahora, simulamos la inicialización.
  Future<void> init({void Function(double)? onProgress}) async {
    if (_isReady || _isInitializing) return;
    _isInitializing = true;

    try {
      // Simulación de descarga
      for (int i = 0; i <= 100; i += 10) {
        await Future.delayed(const Duration(milliseconds: 50));
        onProgress?.call(i / 100.0);
      }
      _isReady = true;
    } catch (e) {
      debugPrint('Error inicializando IA: $e');
    } finally {
      _isInitializing = false;
    }
  }

  /// Corrige la gramática de una secuencia de palabras
  /// 
  /// Si la IA no está lista, devuelve las palabras unidas sin corrección.
  Future<String> fixGrammar(List<String> words) async {
    if (words.isEmpty) return '';

    if (!_isReady) {
      // Modo degradado: simplemente unir palabras
      return words.join(' ');
    }

    // En producción, aquí se llamaría a flutter_gemma:
    // final prompt = 'Corrige la gramática...';
    // final response = await _gemma.generate(prompt);
    // return response;

    // Por ahora, simulamos una corrección simple
    return _simpleGrammarFix(words);
  }

  /// Corrección gramatical básica sin IA
  String _simpleGrammarFix(List<String> words) {
    if (words.isEmpty) return '';

    // Capitalizar primera palabra
    final first = words[0];
    final capitalized = first[0].toUpperCase() + first.substring(1).toLowerCase();

    // Unir con espacios
    final rest = words.skip(1).map((w) => w.toLowerCase()).join(' ');

    // Añadir punto final
    return '$capitalized $rest.';
  }
}