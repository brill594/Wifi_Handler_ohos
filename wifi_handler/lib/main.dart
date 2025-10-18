import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show FontFeature;
import 'dart:convert';
import 'dart:typed_data';
import '../platform/history_api.dart';
import '../models/history_record.dart';



// ===== In-app logger =====
class InAppLog {
  static final ValueNotifier<List<String>> lines = ValueNotifier(<String>[]);
  static void d(String m) {
    final ts = DateTime.now().toIso8601String().split('T').last;
    final line = '[$ts] $m';
    final list = List<String>.from(lines.value)..add(line);
    if (list.length > 400) list.removeRange(0, list.length - 400); // 最多400行
    lines.value = list;
    // 同时打印到调试控制台（即使连不上）
    // ignore: avoid_print
    print(line);
  }
}

class LogConsole extends StatelessWidget {
  const LogConsole({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: InAppLog.lines,
      builder: (_, logs, __) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          height: 220,
          child: Column(
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    const Text('调试日志', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    IconButton(
                      tooltip: '清空',
                      icon: const Icon(Icons.clear_all, size: 18),
                      onPressed: () async {
                        // 如果你想“清空历史记录文件”，可以调用这句：
                        try {
                          InAppLog.d('历史记录已清空');
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('历史记录已清空')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('清空历史失败：$e')),
                            );
                          }
                        }

                        // 同时清空“调试日志面板”的日志（可选）
                        InAppLog.lines.value = <String>[];
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) => Text(
                    logs[i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}


const _fileOps = MethodChannel('file_ops');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}
const _wifiStdChannel = MethodChannel('wifi_std');

Future<Map<String, Map<String, dynamic>>> fetchSystemScanStandards() async {
  try {
    final List<dynamic> raw =
        await _wifiStdChannel.invokeMethod<List<dynamic>>('getScanStandards')
            ?? const [];
    // 用 BSSID 做 key，便于和 wifi_scan 的结果合并
    final map = <String, Map<String, dynamic>>{};
    for (final e in raw) {
      final m = Map<String, dynamic>.from(e as Map);
      final bssid = (m['bssid'] as String?)?.toLowerCase() ?? '';
      if (bssid.isNotEmpty) map[bssid] = m;
    }
    return map;
  } catch (e) {
    debugPrint('fetchSystemScanStandards error: $e');
    return {};
  }
}


Future<void> probePicker() async {
  try {
    final r = await _fileOps.invokeMethod<Map>('saveProbe', {
      'fileName': 'probe_${DateTime.now().millisecondsSinceEpoch}.json'
    });
    InAppLog.d('saveProbe: $r'); // 这里能看到 uris
  } catch (e) {
    InAppLog.d('saveProbe ERROR: $e');
  }
}



// 把系统常量转成人类可读
/// 终极 Wi-Fi 标准判断函数（三层校验）
String determineWifiStandard({
  required int? code,
  required String capabilities,
  required int freq,
  required int bw,
}) {
  // --- 第一层：相信可靠的系统 Code ---
  switch (code) {
    case 8: return '802.11be';
    case 7: return '802.11be';
    case 6: return '802.11ax';
    case 5: return '802.11ac';
    case 4: return '802.11n';
    case 1: return (freq < 2500) ? '802.11b/g' : '802.11a';
  }

  // --- 第二层：如果 Code 不可靠，解析 capabilities 字符串 (最重要！) ---
  final caps = capabilities.toUpperCase();
  // 必须从新到旧判断，因为新标准会兼容旧标准的标识
  if (caps.contains('EHT')) return '802.11be';
  if (caps.contains('HE')) return '802.11ax';
  if (caps.contains('VHT')) return '802.11ac';
  if (caps.contains('HT')) return '802.11n';

  // --- 第三层：如果 capabilities 也无效，启用最终兜底 ---
  if (freq >= 5955) return '802.11ax/be'; // 6GHz 频段
  if (bw >= 320) return '802.11be';
  if (bw >= 160) return '802.11ac/ax/be'; // 160MHz 可能是 ac/ax/be
  if (bw >= 80)  return '802.11ac/ax';   // 80MHz 可能是 ac/ax
  if (bw == 40)  return '802.11n';
  return (freq < 2500) ? '802.11b/g' : '802.11a';
}

// WifiManager 的 channelWidth 常量转 MHz
int channelWidthCodeToMhz(int? code) {
  switch (code) {
    case 5: return 320; // ANDROID 14+
    case 4: return 160; // 80+80 近似按160画
    case 3: return 160;
    case 2: return 80;
    case 1: return 40;
    case 0: return 20;
  }
  return 20;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    const seed = Colors.teal;
    return MaterialApp(
      title: 'Wi-Fi Analyzer',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}

/* ------------------------------ 数据结构 ------------------------------ */

class AP {
  final String ssid;
  final String bssid;
  final int rssi;              // dBm
  final int frequency;         // MHz
  final int channel;           // 中心信道
  final int bandwidthMhz;      // 估算带宽（20/40/80/160/320）
  final String standard;       // 显示用：802.11ax / ac / ...
  final String capabilities;   // 仅展示

  // —— 系统 API 原始字段（用于详情弹窗）——
  final int? wifiStandardCode;     // 1/4/5/6/7（legacy/n/ac/ax/be）
  final String? wifiStandardRaw;   // e.g. WIFI_STANDARD_11AX
  final String? channelWidthRaw;   // e.g. WiFiChannelWidth.width80
  final int? centerFreq0;          // MHz
  final int? centerFreq1;          // MHz

  AP({
    required this.ssid,
    required this.bssid,
    required this.rssi,
    required this.frequency,
    required this.channel,
    required this.bandwidthMhz,
    required this.standard,
    required this.capabilities,
    this.wifiStandardCode,
    this.wifiStandardRaw,
    this.channelWidthRaw,
    this.centerFreq0,
    this.centerFreq1,
  });

  Map<String, dynamic> toJson() => {
    'ssid': ssid,
    'bssid': bssid,
    'rssi': rssi,
    'frequency_mhz': frequency,
    'channel': channel,
    'bandwidth_mhz': bandwidthMhz,
    'standard': standard,
    'wifiStandardCode': wifiStandardCode,
    'wifiStandardRaw': wifiStandardRaw,
    'channelWidthRaw': channelWidthRaw,
    'centerFreq0': centerFreq0,
    'centerFreq1': centerFreq1,
  };
}

String prettyFromWifiCategoryRaw(String? raw) {
  switch (raw) {
    case 'WIFI_CATEGORY_5': return 'Wi-Fi 7+';
    case 'WIFI_CATEGORY_4': return 'Wi-Fi 7';
    case 'WIFI_CATEGORY_3': return 'Wi-Fi 6+';
    case 'WIFI_CATEGORY_2': return 'Wi-Fi 6';
    case 'WIFI_CATEGORY_1': return '≤ Wi-Fi 6';
  }
  return '—';
}

enum Band { any, b24, b5, b6 }

bool _inBand(int f, Band b) {
  switch (b) {
    case Band.any:
      return true;
    case Band.b24:
      return f >= 2400 && f <= 2500;
    case Band.b5:
      return f >= 5000 && f < 5925;
    case Band.b6:
      return f >= 5925 && f <= 7125;
  }
}

/// 频率(MHz) -> 信道号（按常见定义）
/// 2.4G: 2412->1, 2484->14；5G: ch = freq/5 - 1000；6G: ch = (freq-5955)/5 + 1
int freqToChannel(int freq) {
  if (freq == 2484) return 14;
  if (freq >= 2412 && freq <= 2472) return ((freq - 2412) ~/ 5) + 1;
  if (freq >= 5000 && freq <= 5895) return (freq ~/ 5) - 1000;
  if (freq >= 5955 && freq <= 7115) return ((freq - 5955) ~/ 5) + 1;
  return -1;
}
Future<bool> _arkChannelAvailable() async {
  try {
    // 轻量探测：尝试拿一次标准列表；ArkTS 侧没实现会抛 MissingPlugin/404
    await _wifiStdChannel.invokeMethod<List<dynamic>>('getScanStandards');
    return true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return true; // ArkTS 在但方法报错→仍视为通道存在
  } catch (_) {
    return false;
  }
}


List<AP> _mapArkListToAp(List<dynamic> raw) {
  final out = <AP>[];
  for (final e in raw) {
    final m = Map<String, dynamic>.from(e as Map);
    final freq = (m['frequency'] as int?) ?? 0;
    final bw = channelWidthCodeToMhz(m['channelWidthCode'] as int?);
    final caps = (m['capabilities'] as String?) ?? '';
    final label = determineWifiStandard(
      code: m['wifiStandardCode'] as int?,
      capabilities: caps,
      freq: freq,
      bw: bw,
    );
    out.add(AP(
      ssid: m['ssid'] as String? ?? '',
      bssid: (m['bssid'] as String? ?? '').toLowerCase(),
      rssi: (m['level'] as int?) ?? -100,
      frequency: freq,
      channel: freqToChannel(freq),
      bandwidthMhz: bw,
      standard: label,
      capabilities: caps,
      wifiStandardCode: m['wifiStandardCode'] as int?,
      wifiStandardRaw: m['wifiStandardRaw'] as String?,
      channelWidthRaw: m['channelWidthRaw'] as String?,
      centerFreq0: m['centerFreq0'] as int?,
      centerFreq1: m['centerFreq1'] as int?,
    ));
  }
  out.sort((a, b) => b.rssi.compareTo(a.rssi));
  return out;
}

// 从结果对象里尽可能推断带宽（优先 channelWidth，其次解析 capabilities 文本，最后按频段默认）
int _inferBandwidthMhz(dynamic e) {
  try {
    final cw = e.channelWidth; // 可能是枚举
    if (cw != null) {
      final s = cw.toString(); // e.g. WiFiChannelWidth.width80
      if (s.contains('320')) return 320;
      if (s.contains('160')) return 160;
      if (s.contains('80+80')) return 160; // 画图按160处理
      if (s.contains('80')) return 80;
      if (s.contains('40')) return 40;
      if (s.contains('20')) return 20;
    }
  } catch (_) {}
  try {
    final caps = (e.capabilities ?? '') as String;
    if (caps.contains('320')) return 320;
    if (caps.contains('80+80')) return 160;
    if (caps.contains('160')) return 160;
    if (caps.contains('80')) return 80;
    if (caps.contains('40')) return 40;
    if (caps.contains('20')) return 20;
  } catch (_) {}
  // 默认：2.4G -> 20，5/6G -> 20
  return 20;
}

/* ------------------------------ 页面 ------------------------------ */

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<AP> aps = [];
  bool scanning = false;
  String status = '点击“扫描”获取周围 Wi-Fi';
  final remarkCtrl = TextEditingController();
  final searchCtrl = TextEditingController();
  Band band = Band.any;
	String? _lastExportUri;
  File? _lastJsonFile; // 最近保存的 JSON
	@override
	void initState() {
		super.initState();

		_fileOps.setMethodCallHandler((call) async {
			// 统一日志入口
			InAppLog.d('Dart<-ArkTS ${call.method}: ${call.arguments}');

			if (call.method == 'onLog') {
				// 单纯日志
				return null;
			}
			if (call.method == 'onSaved') {
				final m = Map<String, dynamic>.from(call.arguments as Map);
				if (!mounted) return null;
				if (m['ok'] == true) {
					final uri = (m['uri'] ?? '').toString();
					setState(() {
							_lastExportUri = uri;
							_historyUri = uri;                
						});

					ScaffoldMessenger.of(context).showSnackBar(
						SnackBar(content: Text('已导出：$uri')),
					);
				} else {
					ScaffoldMessenger.of(context).showSnackBar(
						SnackBar(content: Text('导出失败：${m['message'] ?? '未知错误'}')),
					);
				}
				return null;
			}
			return null;
		});
	}
	
	String? _historyUri;

	Future<void> _pickHistoryFile() async {
		try {
			final r = await _fileOps.invokeMethod<Map>('chooseOpenUri', {});
			if (r?['ok'] == true && r?['uri'] is String) {
				setState(() => _historyUri = r!['uri'] as String);
				InAppLog.d('history file = $_historyUri');

				// 选完顺便探测一把，日志会进底部面板
				final st = await _fileOps.invokeMethod<Map>('statUri', {'uri': _historyUri});
				InAppLog.d('statUri: $st');
				final peek = await _fileOps.invokeMethod<Map>('history.peek', {'uri': _historyUri, 'max': 400});
				InAppLog.d('history.peek: $peek');
			} else {
				InAppLog.d('chooseOpenUri canceled: $r');
			}
		} catch (e) {
			InAppLog.d('chooseOpenUri ERROR: $e');
		}
	}
	
	Future<void> _probeHistoryUri() async {
		final uri = _historyUri ?? _lastExportUri;
		if (uri == null || uri.isEmpty) {
			ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有已选历史文件')));
			return;
		}
		try {
			final stat = await _fileOps.invokeMethod<Map>('statUri', {'uri': uri});
			InAppLog.d('statUri($uri): $stat');

			final probe = await _fileOps.invokeMethod<Map>('debug.fsProbe', {'uri': uri});
			InAppLog.d('debug.fsProbe: $probe');
		} catch (e) {
			InAppLog.d('probe ERROR: $e');
		}
	}

	Future<void> appendCurrentScanVerbose() async {
		if (_lastExportUri == null) {
			ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先设定导出文件')));
			return;
		}
		if (aps.isEmpty) {
			ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前没有数据可保存')));
			return;
		}

		final entry = {
			'timestamp': DateTime.now().toIso8601String(),
			'remark': remarkCtrl.text.trim(),
			'count': aps.length,
			'results': aps.map((e) => e.toJson()).toList(),
		};
		final line = const JsonEncoder.withIndent('  ').convert(entry) + '\n';
		final raw = utf8.encode(line);
		InAppLog.d('append: rawLen=${raw.length}B');

		try {
			final start = await _fileOps.invokeMethod<Map>('appendStart', {'uri': _lastExportUri});
			InAppLog.d('appendStart -> $start');
			if (start?['ok'] != true) {
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('打开文件失败')));
				return;
			}
			final sid = (start!['sid'] as num).toInt();

			const chunk = 24 * 1024;
			int sent = 0, idx = 0;
			for (int i = 0; i < raw.length; i += chunk) {
				final end = (i + chunk < raw.length) ? i + chunk : raw.length;
				final part = Uint8List.fromList(raw.sublist(i, end));
				final b64 = base64Encode(part);
				final r = await _fileOps.invokeMethod<Map>('appendChunk', {'sid': '$sid', 'b64': b64});
				final wrote = (r?['wrote'] as num?)?.toInt() ?? -1;
				sent += part.length;
				idx++;
				InAppLog.d('appendChunk #$idx raw=${part.length}B b64=${b64.length} sent=$sent/${
						raw.length} wrote=$wrote');
			}

			final fin = await _fileOps.invokeMethod<Map>('appendFinish', {'sid': '$sid'});
			InAppLog.d('appendFinish -> $fin');
		} catch (e) {
			InAppLog.d('export/append error: $e');
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$e')));
		}
	}
	
	Future<void> createFileAndWriteFirstLine(String line) async {
		final fileName = 'wifi_scans.jsonl'; // 固定文件名
		final start = await _fileOps.invokeMethod<Map>('saveStart', {'fileName': fileName});
		if (start?['ok'] != true) {
			InAppLog.d('saveStart canceled/failed: $start');
			return;
		}
		final sid = (start!['sid'] as num).toInt();

		final bytes = Uint8List.fromList(utf8.encode(line));
		const chunk = 24 * 1024; // base64 会膨胀，24KB 更稳
		for (int i = 0; i < bytes.length; i += chunk) {
			final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
			final b64 = base64Encode(bytes.sublist(i, end));
			await _fileOps.invokeMethod('saveChunk', {'sid': '$sid', 'b64': b64});
		}
		await _fileOps.invokeMethod('saveFinish', {'sid': '$sid'});
	}
	
	Future<void> appendLineToKnownUri(String uri, String line) async {
		final start = await _fileOps.invokeMethod<Map>('appendStart', {'uri': uri});
		if (start?['ok'] != true) {
			InAppLog.d('appendStart failed: $start');
			return;
		}
		final sid = (start!['sid'] as num).toInt();

		final bytes = Uint8List.fromList(utf8.encode(line));
		const chunk = 24 * 1024;
		for (int i = 0; i < bytes.length; i += chunk) {
			final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
			final b64 = base64Encode(bytes.sublist(i, end));
			await _fileOps.invokeMethod('appendChunk', {'sid': '$sid', 'b64': b64});
		}
		await _fileOps.invokeMethod('appendFinish', {'sid': '$sid'});
	}
	Future<void> exportOrAppendCurrent() async {
		if (aps.isEmpty) {
			ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前没有数据可保存')));
			return;
		}

		final entry = {
			'timestamp': DateTime.now().toIso8601String(),
			'remark': remarkCtrl.text.trim(),
			'count': aps.length,
			'results': aps.map((e) => e.toJson()).toList(),
		};
		final line = const JsonEncoder.withIndent('  ').convert(entry) + '\n'; // JSONL: 一条一行

		if (_lastExportUri == null) {
			await createFileAndWriteFirstLine(line);   // 第一次：创建固定文件
			// onSaved 回调里会把 _lastExportUri 设为新文件的 URI（你已有）
		} else {
			await appendLineToKnownUri(_lastExportUri!, line); // 后续：直接追加
		}
	}
		
	Future<void> chooseExportFile() async {
		try {
			final r = await _fileOps.invokeMethod<Map>('chooseSaveUri', {'baseName': 'wifi_scans'});
			if (r?['ok'] == true && r?['uri'] is String) {
				setState(() => _lastExportUri = r!['uri'] as String);
				InAppLog.d('chooseExportFile -> $_lastExportUri');
				// 建议同时持久化（可选）
				// final sp = await SharedPreferences.getInstance();
				// await sp.setString('export_uri', _lastExportUri!);
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已设定导出文件')));
			} else {
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已取消选择')));
			}
		} catch (e) {
			InAppLog.d('chooseExportFile ERROR: $e');
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('设定失败：$e')));
		}
	}

	Future<void> appendCurrentScan() async {
		if (_lastExportUri == null) {
			ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先设定导出文件')));
			return;
		}
		if (aps.isEmpty) {
			ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前没有数据可保存')));
			return;
		}

		// 组织一条 JSONL 行
		final entry = {
			'timestamp': DateTime.now().toIso8601String(),
			'remark': remarkCtrl.text.trim(),
			'count': aps.length,
			'results': aps.map((e) => e.toJson()).toList(),
		};
		final line = const JsonEncoder.withIndent('  ').convert(entry) + '\n';

		try {
			// 可选：判断文件是否存在
			final st = await _fileOps.invokeMethod<Map>('statUri', {'uri': _lastExportUri});
			if (st?['ok'] == true && st?['exists'] == false) {
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('目标文件不存在，请重新设定')));
				return;
			}

			final start = await _fileOps.invokeMethod<Map>('appendStart', {'uri': _lastExportUri});
			if (start?['ok'] != true) {
				InAppLog.d('appendStart failed: $start');
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('打开文件失败')));
				return;
			}
			final sid = (start!['sid'] as num).toInt();

			final bytes = Uint8List.fromList(utf8.encode(line));
			const chunk = 24 * 1024; // base64 会膨胀，24KB 更稳
			for (int i = 0; i < bytes.length; i += chunk) {
				final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
				final b64 = base64Encode(bytes.sublist(i, end));
				await _fileOps.invokeMethod('appendChunk', {'sid': '$sid', 'b64': b64});
			}
			await _fileOps.invokeMethod('appendFinish', {'sid': '$sid'});
			// onSaved 回调会提示“已导出：uri”
		} catch (e) {
			InAppLog.d('appendCurrentScan ERROR: $e');
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$e')));
		}
	}
	Future<void> appendTextToUriJsonl({required String uri, required String text}) async {
		try {
			// 开始会话
			final start = await _fileOps.invokeMethod<Map>('appendStart', {'uri': uri});
			if (start?['ok'] != true) {
				InAppLog.d('appendStart failed: $start');
				if (!mounted) return;
				ScaffoldMessenger.of(context).showSnackBar(
					SnackBar(content: Text('打开文件失败：$start')),
				);
				return;
			}
			final sid = (start!['sid'] as num).toInt();

			// 分块发送
			final bytes = utf8.encode(text);
			const chunk = 32 * 1024;
			for (int i = 0; i < bytes.length; i += chunk) {
				final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
				final part = Uint8List.fromList(bytes.sublist(i, end));
				await _fileOps.invokeMethod('appendChunk', {'sid': sid.toString(), 'bytes': part});
			}

			// 完成
			await _fileOps.invokeMethod('appendFinish', {'sid': sid.toString()});
		} catch (e) {
			InAppLog.d('append error: $e');
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('追加失败：$e')),
			);
		}
	}

	// 通过 file_ops 分块保存
	Future<void> exportJsonViaPickerChunked({required String fileName, required String jsonText}) async {
		try {
			// 1) 弹保存器并打开文件
			final start = await _fileOps.invokeMethod<Map>('saveStart', {'fileName': fileName});
			if (start?['ok'] != true) {
				InAppLog.d('saveStart canceled or failed: $start');
				if (!mounted) return;
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已取消保存')));
				return;
			}
			final sid = (start!['sid'] as num).toInt();

			// 2) 分块发送
			final bytes = utf8.encode(jsonText);
			const chunk = 32 * 1024; // 32KB
			for (int i = 0; i < bytes.length; i += chunk) {
				final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
				final part = Uint8List.fromList(bytes.sublist(i, end));
				await _fileOps.invokeMethod('saveChunk', {'sid': sid.toString(), 'bytes': part});
			}

			// 3) 完成
			await _fileOps.invokeMethod('saveFinish', {'sid': sid.toString()});
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('导出完成')));
		} catch (e) {
			InAppLog.d('chunked save ERROR: $e');
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出异常：$e')));
		}
	}

  @override
  void dispose() {
    remarkCtrl.dispose();
    searchCtrl.dispose();
    super.dispose();
  }
  /* ---------- JSON 文件工具 ---------- */

  Future<File> _jsonFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/wifi_scans.json');
  }

  Future<List<dynamic>> _readAllEntries() async {
    final file = await _jsonFile();
    if (await file.exists()) {
      final t = await file.readAsString();
      if (t.trim().isNotEmpty) {
        try {
          final v = jsonDecode(t);
          if (v is List) return v;
        } catch (_) {}
      }
    }
    return [];
  }

  Future<void> _writeAllEntries(List<dynamic> all) async {
    final file = await _jsonFile();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(all), flush: true);
    _lastJsonFile = file;
  }

  /* ---------- 扫描 ---------- */

	Future<void> scanOnce() async {
		setState(() { scanning = true; status = '正在扫描…'; });

		try {
			// 调用 ArkTS 侧：触发扫描 + 取结果
			final raw = await _wifiStdChannel.invokeMethod<List<dynamic>>('scanAndGet') ?? const [];
			final result = _mapArkListToAp(raw);

			setState(() {
				aps = result;
				status = '共发现 ${result.length} 个网络';
			});
		} on PlatformException catch (e) {
			setState(() { status = '扫描失败（平台异常）：${e.message ?? e.code}'; });
		} on MissingPluginException {
			setState(() { status = '扫描失败：未发现 Harmony 通道（wifi_std）。'; });
		} catch (e) {
			setState(() { status = '扫描失败：$e'; });
		} finally {
			if (mounted) setState(() { scanning = false; });
		}
	}


		/* ---------- 保存 / 打开 / 分享 / 导出 ---------- */


	/// 先用 openUri 打开（ArkTS 侧已有），分享功能等你那边补 'shareUri' 再切换
	Future<void> _probeChannels() async {
		await probePicker();
		await sanityProbe();
		try {
			final res = await _fileOps.invokeMethod('ping'); // 不写 <bool>
			final ok = res == true || (res is Map && res['ok'] == true);

			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('file_ops 通道 ${ok ? "OK" : "未响应"}（$res）')),
			);
		} on MissingPluginException {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				const SnackBar(content: Text('file_ops 通道缺失（MissingPluginException）')),
			);
		} catch (e) {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('file_ops 调用异常：$e')),
			);
		}
	}
	Future<void> sanityProbe() async {
  // 1) file_ops ping/echo
  try {
    final p1 = await _fileOps.invokeMethod('ping');
    InAppLog.d('file_ops ping: $p1');
  } catch (e) {
    InAppLog.d('file_ops ping ERROR: $e');
  }
  try {
    final e1 = await _fileOps.invokeMethod('echo', {'v': 'hi'});
    InAppLog.d('file_ops echo: $e1');
  } catch (e) {
    InAppLog.d('file_ops echo ERROR: $e');
  }

  // 2) wifi_std ping/echo
  try {
    final p2 = await _wifiStdChannel.invokeMethod('ping');
    InAppLog.d('wifi_std ping: $p2');
  } catch (e) {
    InAppLog.d('wifi_std ping ERROR: $e');
  }
  try {
    final e2 = await _wifiStdChannel.invokeMethod('echo', {'v': 'hi'});
    InAppLog.d('wifi_std echo: $e2');
  } catch (e) {
    InAppLog.d('wifi_std echo ERROR: $e');
  }
}

	Future<void> exportJsonViaPickerStart({bool onlyCurrent = false}) async {
		try {
			InAppLog.d('Dart->ArkTS saveToDownloads: prepare payload');
			final all = onlyCurrent
					? [
							{
								'timestamp': DateTime.now().toIso8601String(),
								'remark': remarkCtrl.text.trim(),
								'count': aps.length,
								'results': aps.map((e) => e.toJson()).toList(),
							}
						]
					: await _readAllEntries();
			final text = const JsonEncoder.withIndent('  ').convert(all);
			final safe = text.length > 1000 ? text.substring(0, 1000) : text; // 临时截断
			final fileName = 'wifi_scans_${DateTime.now().toIso8601String().replaceAll(':', '-')}.json';
			final echo = await _fileOps.invokeMethod<Map>('echo', {'v': 'hi'});
			InAppLog.d('echo: $echo');

			InAppLog.d('Dart->ArkTS saveToDownloads: invoke');
			final res = await _fileOps.invokeMethod<Map>('saveToDownloads', {
				'fileName': fileName,
				'text': safe,
			});

			InAppLog.d('Dart<-ArkTS saveToDownloads immediate: $res');
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				const SnackBar(content: Text('已打开系统保存器，请完成保存操作…')),
			);
		} on PlatformException catch (e) {
			InAppLog.d('Dart exception PlatformException in saveToDownloads: $e');
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('导出异常：$e')),
			);
		} catch (e) {
			InAppLog.d('Dart exception saveToDownloads: $e');
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('导出异常：$e')),
			);
		}
	}


	Future<void> openLastExported(String uri) async {
		try {
			final res = await _fileOps.invokeMethod<Map>('openUri', {'uri': uri});
			if (res?['ok'] != true && mounted) {
				ScaffoldMessenger.of(context).showSnackBar(
					SnackBar(content: Text('打开失败：${res?['message'] ?? '未知错误'}')),
				);
			}
		} on MissingPluginException {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				const SnackBar(content: Text('file_ops 通道缺失（MissingPluginException）')),
			);
		} catch (e) {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('打开异常：$e')),
			);
		}
	}

	
  Future<void> saveToJson() async {
    if (aps.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有扫描结果可保存。')),
      );
      return;
    }

    final all = await _readAllEntries();
    final entry = {
      'timestamp': DateTime.now().toIso8601String(),
      'remark': remarkCtrl.text.trim(),
      'count': aps.length,
      'results': aps.map((e) => e.toJson()).toList(),
    };
    all.add(entry);
    await _writeAllEntries(all);

    if (!mounted) return;
    final f = _lastJsonFile!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已保存到 ${f.path.split('/').last}（应用文档目录）'),
        action: SnackBarAction(label: '打开', onPressed: _openJson),
      ),
    );
  }

	Future<void> _openJson() async {
		final f = _lastJsonFile ?? await _jsonFile();
		if (await f.exists()) {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('已保存：${f.path}')),
			);
		} else {
			if (!mounted) return;
			ScaffoldMessenger.of(context)
					.showSnackBar(const SnackBar(content: Text('尚未生成 wifi_scans.json')));
		}
	}


  /* ---------- 历史记录（查看/删除） ---------- */

	Future<void> _openHistory() async {
		final changed = await Navigator.of(context).push<bool>(
			MaterialPageRoute(builder: (_) => HistoryPage(externalUri: _lastExportUri)),
		);
		if (changed == true && mounted) {
			ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('历史已更新')));
		}
	}


  /* ---------- 过滤 ---------- */

  List<AP> get _filtered {
    final q = searchCtrl.text.trim().toLowerCase();
    return aps.where((e) {
      final okBand = _inBand(e.frequency, band);
      final okQuery =
          q.isEmpty || e.ssid.toLowerCase().contains(q) || e.bssid.toLowerCase().contains(q);
      return okBand && okQuery;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    final hasData = list.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        actions: [
					IconButton(
						tooltip: '设定导出文件（wifi_scans.jsonl）',
						onPressed: chooseExportFile,
						icon: const Icon(Icons.create_new_folder_outlined),
					),

					// 步骤 2：把本次扫描追加到同一个文件
					IconButton(
						tooltip: '保存当前（追加到同一文件）',
						onPressed: appendCurrentScanVerbose,
						icon: const Icon(Icons.download_outlined),
					),

					IconButton(
						tooltip: '打开导出的 JSON',
						onPressed: _lastExportUri == null
								? null
								: () => openLastExported(_lastExportUri!),
						icon: const Icon(Icons.insert_drive_file_outlined), 
					),
					IconButton(
						tooltip: '探测历史文件',
						icon: const Icon(Icons.search),
						onPressed: _probeHistoryUri,
					),
					IconButton(
						tooltip: '历史',
						icon: const Icon(Icons.history),
						onPressed: () async {
							if (_lastExportUri == null || _lastExportUri!.isEmpty) {
								await chooseExportFile();  // 或你自己的 _pickHistoryFile()
								if (_lastExportUri == null || _lastExportUri!.isEmpty) {
									ScaffoldMessenger.of(context).showSnackBar(
										const SnackBar(content: Text('请先选择/创建历史文件（json/jsonl/jsonl）')),
									);
									return;
								}
							}
							final uri = _lastExportUri!;               // 此时已保证非空
							await Navigator.of(context).push(
								MaterialPageRoute(builder: (_) => HistoryPage(externalUri: uri)),
							);
						},
					),
					IconButton(
						tooltip: '自检通道',
						onPressed: _probeChannels,
						icon: const Icon(Icons.bug_report),
					),
        ],
      ),
      body: Column(
        children: [
          // 工具条
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: remarkCtrl,
                        decoration: const InputDecoration(
                          labelText: '备注（可选）',
                          hintText: '例如：客厅，10月7日上午',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: scanning ? null : scanOnce,
                      icon: const Icon(Icons.wifi_tethering),
                      label: Text(scanning ? '扫描中…' : '扫描'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SegmentedButton<Band>(
                      segments: const [
                        ButtonSegment(value: Band.any, label: Text('全部')),
                        ButtonSegment(value: Band.b24, label: Text('2.4G')),
                        ButtonSegment(value: Band.b5, label: Text('5G')),
                        ButtonSegment(value: Band.b6, label: Text('6G')),
                      ],
                      selected: {band},
                      onSelectionChanged: (s) => setState(() => band = s.first),
                      showSelectedIcon: false,
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: searchCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: '搜索 SSID 或 BSSID',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    status,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),

          // 图表
          Expanded(
            flex: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                ),
                child: CustomPaint(
                  painter: WifiChartPainter(aps: list, brightness: Theme.of(context).brightness),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),

          // 表格（替代之前的横向卡片）
          Expanded(
            flex: 7,
            child: _ApTable(data: list),
          ),
        ],
      ),
			bottomSheet: ExpansionTile(
				initiallyExpanded: true, // 需要时改成 false
				title: const Text('调试面板'),
				children: const [LogConsole()],
			),
    );
  }
}

/* ------------------------------ 表格控件 ------------------------------ */

class _ApTable extends StatelessWidget {
  final List<AP> data;
  const _ApTable({required this.data});

  void _showDetail(BuildContext context, AP ap) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final onBg = Theme.of(ctx).colorScheme.onSurfaceVariant;
        final mono = TextStyle(fontFeatures: const [FontFeature.tabularFigures()], color: onBg);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),
              Text(ap.ssid.isEmpty ? '<隐藏SSID>' : ap.ssid,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(ap.bssid, style: mono),
              const Divider(height: 16),
              _kv('标准', ap.standard),
              _kv('系统 wifiStandardCode', ap.wifiStandardCode?.toString() ?? '—'),
							_kv('系统级别(HW)', prettyFromWifiCategoryRaw(ap.wifiStandardRaw)),
              _kv('channelWidthRaw', ap.channelWidthRaw ?? '—'),
              _kv('centerFreq0 / 1', '${ap.centerFreq0 ?? '—'} / ${ap.centerFreq1 ?? '—'} MHz'),
              _kv('频率 / 信道', '${ap.frequency} MHz / ch ${ap.channel}'),
              _kv('带宽', '${ap.bandwidthMhz} MHz'),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('capabilities'),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(ctx).dividerColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      ap.capabilities.isEmpty ? '（空）' : ap.capabilities,
                      style: mono,
                    ),
                  )
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(k)),
          Expanded(child: Text(v, maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const Center(child: Text('没有数据'));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final table = DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 44,
            columns: const [
              DataColumn(label: Text('名称')),
              DataColumn(label: Text('设备')),
              DataColumn(label: Text('强度')),
              DataColumn(label: Text('频率')),
              DataColumn(label: Text('信道')),
              DataColumn(label: Text('带宽')),
              DataColumn(label: Text('标准')), // ← 这里有 ℹ️
            ],
            rows: data.map((ap) {
              return DataRow(cells: [
                DataCell(SizedBox(width: 160, child: Text(ap.ssid.isEmpty ? '<隐藏SSID>' : ap.ssid, overflow: TextOverflow.ellipsis))),
                DataCell(SizedBox(width: 160, child: Text(ap.bssid, overflow: TextOverflow.ellipsis))),
                DataCell(Text('${ap.rssi} dBm')),
                DataCell(Text('${ap.frequency} MHz')),
                DataCell(Text('${ap.channel}')),
                DataCell(Text('${ap.bandwidthMhz} MHz')),
                DataCell(SizedBox(
                  width: 150,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(ap.standard, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '查看系统字段',
                        icon: const Icon(Icons.info_outline, size: 18),
                        onPressed: () => _showDetail(context, ap),
                      ),
                    ],
                  ),
                )),
              ]);
            }).toList(),
          );

          // 纵向 + 横向双滚动
          return Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: table,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}



/* ------------------------------ 历史页：查看 + 删除 ------------------------------ */


class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.externalUri});
  final String? externalUri;
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<HistoryRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = (widget.externalUri != null && widget.externalUri!.isNotEmpty)
        ? HistoryApi.listFromUri(widget.externalUri!, limit: 200)
        : Future.value(const <HistoryRecord>[]);
  }

  void _reload() {
    setState(() {
      _future = (widget.externalUri != null && widget.externalUri!.isNotEmpty)
          ? HistoryApi.listFromUri(widget.externalUri!, limit: 200)
          : Future.value(const <HistoryRecord>[]);
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史记录（外部文件）'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),


        ],
      ),
      body: FutureBuilder<List<HistoryRecord>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const <HistoryRecord>[];
          if (items.isEmpty) return const Center(child: Text('暂无历史记录'));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = items[i];
              final title = (r.payload['title'] ??
                             r.payload['ssid'] ??
                             r.payload['name'] ??
                             r.payload['text'] ??
                             '记录').toString();
              return ListTile(
                title: Text(title),
                subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(r.time)} · ${r.payload}',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: '删除这一条',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: (widget.externalUri == null)
                      ? null
                      : () async {
                          final ok = await HistoryApi.deleteFromUri(
                            uri: widget.externalUri!,
                            t: r.time,
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(ok ? '已删除' : '删除失败')),
                          );
                          if (ok) _reload();
                        },
                ),
              );
            },
          );
        },
      ),
    );
  }
}


/* ------------------------------ 绘图（平顶台形） ------------------------------ */

class WifiChartPainter extends CustomPainter {
  final List<AP> aps;
  final Brightness brightness;
  WifiChartPainter({required this.aps, required this.brightness});

  static const int minRssi = -100;
  static const int maxRssi = -30;

  @override
  void paint(Canvas canvas, Size size) {
    final padding = const EdgeInsets.fromLTRB(48, 16, 12, 40);
    final chart = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.left - padding.right,
      size.height - padding.top - padding.bottom,
    );

    final textColor = brightness == Brightness.dark ? Colors.white : Colors.black87;
    final gridColor = (brightness == Brightness.dark ? Colors.white70 : Colors.black87).withOpacity(0.22);
    final axisColor = gridColor.withOpacity(0.55);

    // 水平网格
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = gridColor;
    const rows = 7;
    for (int i = 0; i <= rows; i++) {
      final y = chart.top + i * chart.height / rows;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }

    // 外框
    final axis = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = axisColor;
    canvas.drawRect(chart, axis);

    // 仅占用信道决定范围
    final occupied = aps.map((e) => e.channel).where((c) => c > 0).toSet().toList()..sort();
    int minCh, maxCh;
    if (occupied.isEmpty) {
      minCh = 1;
      maxCh = 165;
    } else {
      minCh = (occupied.first - 3).clamp(1, 1000);
      maxCh = (occupied.last + 3).clamp(minCh + 10, 1000);
    }

    double xOf(num ch) => chart.left + ((ch - minCh) / (maxCh - minCh)) * chart.width;
    double yOf(int rssi) {
      final rr = rssi.clamp(minRssi, maxRssi).toDouble();
      final t = (rr - minRssi) / (maxRssi - minRssi);
      return chart.bottom - t * chart.height;
    }

    // 刻度
    for (int r = -100; r <= -30; r += 10) {
      final y = yOf(r);
      _drawText(canvas, '$r dBm', Offset(padding.left - 44, y - 7),
          TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
    }
    if (occupied.isNotEmpty) {
      final step = (occupied.length <= 18) ? 1 : (occupied.length / 18).ceil();
      for (int i = 0; i < occupied.length; i += step) {
        final ch = occupied[i];
        final x = xOf(ch);
        canvas.drawLine(Offset(x, chart.bottom), Offset(x, chart.bottom + 4), axis);
        _drawText(canvas, '$ch', Offset(x - 6, chart.bottom + 6),
            TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
      }
    }

    // 调色板
    final palette = brightness == Brightness.dark
        ? [Colors.cyanAccent, Colors.orangeAccent, Colors.pinkAccent, Colors.lightGreenAccent, Colors.amberAccent, Colors.blueAccent, Colors.limeAccent, Colors.tealAccent]
        : [Colors.blue.shade800, Colors.red.shade700, Colors.green.shade700, Colors.purple.shade700, Colors.orange.shade800, Colors.indigo.shade800, Colors.teal.shade800, Colors.brown.shade700];

    // 平顶台形：左右斜边+平顶，脚落在底线
    int colorIdx = 0;
    int labelIdx = 0;
    final baseY = chart.bottom - 1;

    for (final ap in aps.where((e) => e.channel > 0)) {
      final color = palette[colorIdx++ % palette.length];

      final widthCh = (ap.bandwidthMhz / 5.0); // MHz -> 信道宽度
      final slopeCh = widthCh * 0.18;          // 斜边宽度（18%）
      final leftBase = ap.channel - widthCh / 2;
      final rightBase = ap.channel + widthCh / 2;
      final leftTop = leftBase + slopeCh;
      final rightTop = rightBase - slopeCh;

      final topY = yOf(ap.rssi);

      final path = Path()
        ..moveTo(xOf(leftBase), baseY)         // 左脚
        ..lineTo(xOf(leftTop), topY)           // 左斜边上升
        ..lineTo(xOf(rightTop), topY)          // 平顶
        ..lineTo(xOf(rightBase), baseY)        // 右斜边下降
        ..close();

      final bounds = Rect.fromLTRB(xOf(leftBase), topY, xOf(rightBase), baseY);
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.28), color.withOpacity(0.06)],
        ).createShader(bounds);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color;

      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);

      // 标签（半透明底）
      final label = ap.ssid.isEmpty ? ap.bssid : ap.ssid;
      final tp = _measure(label,
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
          maxWidth: 160);
      final cx = xOf(ap.channel.toDouble());
      final dy = 14 + (labelIdx++ % 3) * 10;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - tp.width / 2 - 6, topY - tp.height - dy, tp.width + 12, tp.height + 6),
        const Radius.circular(6),
      );
      final bg = Paint()..color = Colors.black.withOpacity(0.45);
      canvas.drawRRect(rect, bg);
      tp.paint(canvas, Offset(rect.left + 6, rect.top + 3));
    }

    _drawText(canvas, 'RSSI (dBm)', Offset(8, chart.top - 12),
        TextStyle(fontSize: 12, color: textColor));
    _drawText(canvas, '信道 (Channel)', Offset(chart.right - 110, chart.bottom + 22),
        TextStyle(fontSize: 12, color: textColor));
  }

  @override
  bool shouldRepaint(covariant WifiChartPainter old) =>
      old.aps != aps || old.brightness != brightness;

  TextPainter _measure(String s, TextStyle style, {double maxWidth = 200}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(minWidth: 0, maxWidth: maxWidth);
    return tp;
  }

  void _drawText(Canvas canvas, String s, Offset p, TextStyle style) {
    final tp = _measure(s, style);
    tp.paint(canvas, p);
  }
}
