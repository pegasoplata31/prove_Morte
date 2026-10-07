import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// Persistencia local de señas y configuración
class Storage {
  static const String _signsKey = 'beyond_words_signs';
  static const String _restVectorKey = 'beyond_words_rest';
  static const String _settingsKey = 'beyond_words_settings';

  /// Guarda todas las señas
  static Future<void> saveGestures(List<Gesture> gestures) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(gestures.map((g) => g.toJson()).toList());
    await prefs.setString(_signsKey, json);
  }

  /// Carga todas las señas
  static Future<List<Gesture>> loadGestures() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_signsKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final list = jsonDecode(jsonStr) as List;
      return list.map((e) => Gesture.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      return [];
    }
  }

  /// Guarda vector de reposo (postura neutral)
  static Future<void> saveRestVector(BimanualVector vector) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_restVectorKey, jsonEncode(vector.values));
  }

  /// Carga vector de reposo
  static Future<BimanualVector?> loadRestVector() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_restVectorKey);
    if (jsonStr == null) return null;
    final list = (jsonDecode(jsonStr) as List).cast<double>();
    return BimanualVector(list);
  }

  /// Guarda configuración (idioma, velocidad, etc.)
  static Future<void> saveSettings(Map<String, dynamic> settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings));
  }

  /// Carga configuración
  static Future<Map<String, dynamic>> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_settingsKey);
    if (jsonStr == null) return {};
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }
}