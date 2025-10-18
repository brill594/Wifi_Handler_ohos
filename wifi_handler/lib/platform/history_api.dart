import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/history_record.dart';

class HistoryApi {
  static const MethodChannel _ch = MethodChannel('file_ops');

  /// 兼容旧接口（私有目录已停用）：直接返回空列表，避免编译错误
  static Future<List<HistoryRecord>> list({int limit = 200}) async {
    return const <HistoryRecord>[];
  }

  /// 兼容旧接口（私有目录已停用）：假成功
  static Future<bool> clear() async {
    return true;
  }
	
  static Future<bool> deleteFromUri({required String uri, required int t}) async {
    try {
      final res = await _ch.invokeMethod<Map>('history.deleteFromUri', {
        'uri': uri,
        't': t.toString(),
      });
      return res?['ok'] == true;
    } catch (_) {
      return false;
    }
  }
	
  /// 从外部 URI 读取（ArkTS: history.listFromUri），推荐使用
  static Future<List<HistoryRecord>> listFromUri(String uri, {int limit = 200}) async {
    try {
      final res = await _ch.invokeMethod<Map>('history.listFromUri', {
        'uri': uri,
        'limit': limit,
      });
      if (res?['ok'] == true && res?['data'] is List) {
        final arr = (res!['data'] as List).whereType<Map>();
        // ArkTS 端返回 {t:number, payload:string}，这里把 payload 再转 Map
        return arr
            .map((m) => HistoryRecord.fromTextRow(Map<dynamic, dynamic>.from(m)))
            .toList(growable: false);
      }
    } catch (_) {}
    return const <HistoryRecord>[];
  }

  /// 清空外部 URI 文件（ArkTS: truncateUri）
  static Future<bool> clearFromUri(String uri) async {
    try {
      final res = await _ch.invokeMethod<Map>('truncateUri', {'uri': uri});
      return res?['ok'] == true;
    } catch (_) {
      return false;
    }
  }
}
