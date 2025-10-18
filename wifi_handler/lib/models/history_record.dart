// lib/models/history_record.dart
import 'dart:convert';

class HistoryRecord {
  final int time;
  final Map<String, dynamic> payload;
  HistoryRecord({required this.time, required this.payload});

  factory HistoryRecord.fromTextRow(Map m) {
    final t = (m['t'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final p = m['payload'];
    Map<String, dynamic> obj = const {};
    if (p is String) {
      try {
        final dec = jsonDecode(p);
        if (dec is Map) obj = Map<String, dynamic>.from(dec);
      } catch (_) {}
    } else if (p is Map) {
      obj = Map<String, dynamic>.from(p);
    }
    return HistoryRecord(time: t, payload: obj);
  }
}
