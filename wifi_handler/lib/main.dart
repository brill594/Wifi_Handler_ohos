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
import 'dart:async';
import 'package:flutter/services.dart' show rootBundle;
import 'dart:typed_data';
import 'package:http/http.dart' as http;

final GlobalKey _aiCardKey = GlobalKey();



class VendorDb {
  // 使用 Map<String, dynamic> 以匹配 jsonDecode 的结果
  static Map<String, dynamic> _vendorMap = {};
  static bool _isInitialized = false;

  /// 应用启动时调用
  static Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      final jsonString = await rootBundle.loadString('assets/oui_vendor.json');
      _vendorMap = jsonDecode(jsonString); // 直接加载
      _isInitialized = true;
      InAppLog.d('Loaded vendor OUI database with ${_vendorMap.length} entries.');
    } catch (e) {
      InAppLog.d('Failed to load vendor OUI database: $e');
    }
  }

  /// 查找厂商
  static String lookup(String bssid) {
    if (!_isInitialized || bssid.length < 8) return 'Unknown Vendor';
    // OUI 是前 8 个字符 (AA:BB:CC)
    final oui = bssid.substring(0, 8).toUpperCase();
    // 从 Map 中查找，并确保返回 String
    return (_vendorMap[oui] as String?) ?? 'Unknown Vendor';
  }
}

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

// (!!) 新增：设置服务 (纯 Dart 内存版)
class SettingsService with ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  String _apiKey = '';
  // (!!) 存储基础域名，而不是完整 URL
  String _apiBaseDomain = 'api.openai.com'; 
  String _modelName = 'gpt-4o-mini';

  ThemeMode get themeMode => _themeMode;
  String get apiKey => _apiKey;
  // (!!) Getter 动态计算完整 URL
  String get apiEndpoint {
    if (_apiBaseDomain.isEmpty) return 'https://api.openai.com/v1/chat/completions';
    // 自动补全
    final domain = _apiBaseDomain.replaceAll('http://', '').replaceAll('https://', '');
    return 'https://$domain/v1/chat/completions';
  }
  String get apiBaseDomain => _apiBaseDomain; // (!!) Getter for settings page
  String get modelName => _modelName; 

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }

  // (!!) setAiConfig 现在接收 baseDomain
  void setAiConfig(String key, String baseDomain, String model) {
    _apiKey = key;
    // 移除 http(s):// 前缀和末尾的 /
    _apiBaseDomain = baseDomain
        .replaceAll('http://', '')
        .replaceAll('https://', '')
        .trim();
    if (_apiBaseDomain.endsWith('/')) {
       _apiBaseDomain = _apiBaseDomain.substring(0, _apiBaseDomain.length - 1);
    }
        
    if (_apiBaseDomain.isEmpty) _apiBaseDomain = 'api.openai.com';
    
    _modelName = model.isEmpty ? 'gpt-4o-mini' : model;
    notifyListeners();
  }
}

class AiAnalyzerService {
  static Future<String> analyze({
    required String historyPayloadJson,
    required String apiKey,
    required String apiEndpoint,
    required String languageCode,
    required String modelName, // (!!) 新增模型参数
  }) async {
    if (apiKey.isEmpty) {
      return '错误：未在设置页面配置 API Key。';
    }

    // (!!) 修改 Prompt，移除 currentWifiSsid
    final String prompt = """
您是一个精通 Wi-Fi 网络优化的助手。请分析以下数据并提供网络改善建议。
以下 JSON 数据是用户从历史记录中加载的 Wi-Fi 环境快照。'results' 键包含了当时检测到的所有 AP 列表。

请重点分析:
1. 信道重叠：特别是 2.4GHz 频段（1, 6, 11 信道最佳）。
2. 信号强度 (rssi)：分析哪些 AP 信号最强，哪些信号最弱。
3. 网络标准 (standard) 和带宽 (bandwidthMhz)：例如 '802.11ax' 和 '80 MHz'。
4. 根据整个环境的拥挤程度，为用户提供通用的 Wi-Fi 优化建议（例如：如果 2.4G 拥挤，建议切换到 5G/6G；如果信道重叠严重，建议检查路由器设置并调整信道）。

请必须使用此语言代码进行回复: '$languageCode'。

JSON 数据如下:
$historyPayloadJson
""";

    try {
      final response = await http.post(
        Uri.parse(apiEndpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': modelName, // (!!) 使用传入的模型
          'messages': [
            {'role': 'system', 'content': 'You are a helpful Wi-Fi network assistant.'},
            {'role': 'user', 'content': prompt},
          ],
        }),
      );
      // [ ... 后续的 http 逻辑保持不变 ... ]
      if (response.statusCode == 200) {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        return body['choices'][0]['message']['content'] as String;
      } else {
        final errorBody = utf8.decode(response.bodyBytes);
        InAppLog.d('AI analyze error ${response.statusCode}: $errorBody');
        return 'AI 分析失败 (Code: ${response.statusCode})：\n$errorBody';
      }
    } catch (e) {
      InAppLog.d('AI analyze request error: $e');
      return 'AI 请求异常：\n$e';
    }
  }
}


// (!!) 全局实例化设置服务
final SettingsService settingsService = SettingsService();


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
	await VendorDb.initialize();
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
    case 1: return (freq < 2500) ? '802.11ac及以下' : '802.11ac及以下';
  }

  // --- 第二层：如果 Code 不可靠，解析 capabilities 字符串 (最重要！) ---
  final caps = capabilities.toUpperCase();
  // 必须从新到旧判断，因为新标准会兼容旧标准的标识
  if (caps.contains('EHT')) return '802.11be';
  if (caps.contains('HE')) return '802.11ax';
  if (caps.contains('VHT')) return '802.11ac及以下';
  if (caps.contains('HT')) return '802.11n';

  // --- 第三层：如果 capabilities 也无效，启用最终兜底 ---
  if (freq >= 5955) return '802.11ax/be'; // 6GHz 频段
  if (bw >= 320) return '802.11be';
  if (bw >= 160) return '802.11ac/ax/be'; // 160MHz 可能是 ac/ax/be
  if (bw >= 80)  return '802.11ac/ax(系统未返回)';   // 80MHz 可能是 ac/ax
  if (bw == 40)  return '802.11n';
  return (freq < 2500) ? '802.11ac及以下' : '802.11ac及以下';
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
    
    // (!!) 将 MaterialApp 包裹在 ListenableBuilder 中以监听主题变化
    return ListenableBuilder(
      listenable: settingsService,
      builder: (context, child) {
        return MaterialApp(
          title: 'Wi-Fi Analyzer',
          debugShowCheckedModeBanner: false,
          themeMode: settingsService.themeMode, // (!!) 使用服务中的 themeMode
          theme: ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.light),
          darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.dark),
          home: const HomePage(),
        );
      },
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
	double _chartZoom = 1.0; 
  final ScrollController _chartScrollController = ScrollController();
	int _pageIndex = 0; // <-- 保持不变
	
	@override
	void initState() {
    // [initState... 保持不变]
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
		_chartScrollController.dispose(); // 新增：释放控制器
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
// --- 新增的UI构建方法 ---

  // 构建概览页的 AppBar
  AppBar _buildOverviewAppBar() {
    return AppBar(
			title: const Text('WiFi Handler'),
      actions: [
        IconButton(
          tooltip: '设定导出文件（wifi_scans.jsonl）',
          onPressed: chooseExportFile,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
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
          tooltip: '历史',
          icon: const Icon(Icons.history),
          onPressed: () async {
            if (_lastExportUri == null || _lastExportUri!.isEmpty) {
              await chooseExportFile();
              if (_lastExportUri == null || _lastExportUri!.isEmpty) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请先选择/创建历史文件（json/jsonl/jsonl）')),
                );
                return;
              }
            }
            final uri = _lastExportUri!;
            if (!mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => HistoryPage(externalUri: uri)),
            );
          },
        ),
      ],
    );
  }

  // 构建调试页的 AppBar
  AppBar _buildDebugAppBar() {
    return AppBar(
      title: const Text('调试'),
      actions: [
        IconButton(
          tooltip: '探测历史文件',
          icon: const Icon(Icons.search),
          onPressed: _probeHistoryUri,
        ),
        IconButton(
          tooltip: '自检通道',
          onPressed: _probeChannels,
          icon: const Icon(Icons.bug_report),
        ),
      ],
    );
  }
	
// (!!) 新增：构建分析页的 AppBar
  AppBar _buildAnalysisAppBar() {
    return AppBar(
      title: const Text('分析'),
    );
  }
	
  // 构建概览页的主体内容
  Widget _buildOverviewBody() {
    final list = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
                    style: const ButtonStyle(
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
          flex: 10,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        controller: _chartScrollController,
                        child: SizedBox(
                          width: (MediaQuery.of(context).size.width - 24) * _chartZoom,
                          child: CustomPaint(
                            painter: WifiChartPainter(aps: list, brightness: Theme.of(context).brightness),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    const Text('缩放'),
                    Expanded(
                      child: Slider(
                        value: _chartZoom,
                        min: 1.0,
                        max: 5.0,
                        divisions: 16,
                        label: 'x${_chartZoom.toStringAsFixed(1)}',
                        onChanged: (value) {
                          setState(() {
                            _chartZoom = value;
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 表格
        Expanded(
          flex: 7,
          child: _ApTable(data: list),
        ),
      ],
    );
  }

  // 构建调试页的主体内容
  Widget _buildDebugBody() {
    return const LogConsole();
  }
@override
  Widget build(BuildContext context) {
    // 根据当前页面索引，准备好对应的 AppBar 和 body
    final List<PreferredSizeWidget?> appBars = [
      _buildOverviewAppBar(),
			_buildAnalysisAppBar(),
			AppBar(title: const Text('设置')),
      _buildDebugAppBar(),
    ];
    final List<Widget> pages = [
      _buildOverviewBody(),
			AnalysisPage(externalUri: _lastExportUri),
			const SettingsPage(), // (!!) 新增设置页
      _buildDebugBody(),
    ];

		return Scaffold(
      appBar: appBars[_pageIndex],
      body: pages[_pageIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _pageIndex,
        onTap: (index) {
          setState(() {
            _pageIndex = index;
          });
        },
        // (!!) 修改：确保 .fixed 类型
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 10.0, 
        unselectedFontSize: 10.0,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.analytics_outlined),
            label: '概览',
          ),
          // (!!) 新增
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart_outlined),
            label: '分析',
          ),
					BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            label: '设置',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bug_report_outlined),
            label: '调试',
          ),
        ],
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
              DataColumn(label: Text('标准')),
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
  // (!!) 修改构造函数
  const HistoryPage({
    super.key,
    this.externalUri,
    this.isSelectionMode = false, // 默认是查看模式
  });
  final String? externalUri;
  final bool isSelectionMode; // (!!) 新增

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
        // (!!) 修改标题
        title: Text(widget.isSelectionMode
            ? '选择一个历史记录'
            : '历史记录（外部文件）'), //
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
              //
              final title = (r.payload['title'] ??
                      r.payload['remark'] ?? // (!!) 增加 'remark' 字段
                      r.payload['ssid'] ??
                      r.payload['name'] ??
                      r.payload['text'] ??
                      '记录')
                  .toString();
              return ListTile(
                // (!!) 新增 onTap
                onTap: widget.isSelectionMode
                    ? () {
                        // 如果是选择模式，点击时返回 HistoryRecord
                        Navigator.of(context).pop(r);
                      }
                    : null, // 查看模式下，点击无效果
                title: Text(title.isEmpty ? '（无备注）' : title),
                subtitle: Text(
                    '${DateTime.fromMillisecondsSinceEpoch(r.time)} · ${(r.payload['results'] as List?)?.length ?? 0} 个AP',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                // (!!) 修改 trailing
                trailing: widget.isSelectionMode
                    ? const Icon(Icons.chevron_right) // 选择模式显示箭头
                    : IconButton( // 查看模式显示删除按钮
                        tooltip: '删除这一条',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: (widget.externalUri == null)
                            ? null
                            : () async {
                                final ok = await HistoryApi.deleteFromUri( //
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
typedef _ChannelRange = ({double start, double end});

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

    // Draw Y-axis grid and labels (no changes here)
    final grid = Paint()
      ..style = PaintingStyle.stroke..strokeWidth = 0.5..color = gridColor;
    const rows = 7;
    for (int i = 0; i <= rows; i++) {
      final y = chart.top + i * chart.height / rows;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }
    final axis = Paint()
      ..style = PaintingStyle.stroke..strokeWidth = 1..color = axisColor;
    canvas.drawRect(chart, axis);

    double yOf(int rssi) {
      final rr = rssi.clamp(minRssi, maxRssi).toDouble();
      final t = (rr - minRssi) / (maxRssi - minRssi);
      return chart.bottom - t * chart.height;
    }
    for (int r = -100; r <= -30; r += 10) {
      final y = yOf(r);
      _drawText(canvas, '$r dBm', Offset(padding.left - 44, y - 7),
          TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
    }

    // --- NEW LOGIC: Dynamic X-Axis based on active channels ---
    if (aps.where((e) => e.channel > 0).isEmpty) {
      _drawText(canvas, '信道 (Channel)', Offset(chart.right - 110, chart.bottom + 22), TextStyle(fontSize: 12, color: textColor));
      _drawText(canvas, 'RSSI (dBm)', Offset(chart.left, 2), TextStyle(fontSize: 12, color: textColor));
      return; // No APs to draw
    }

    // 1. Build and merge active channel ranges
    final List<_ChannelRange> ranges = [];
    for (final ap in aps.where((e) => e.channel > 0)) {
      final widthCh = ap.bandwidthMhz / 5.0;
      ranges.add((start: ap.channel - widthCh / 2, end: ap.channel + widthCh / 2));
    }
    ranges.sort((a, b) => a.start.compareTo(b.start));

    final List<_ChannelRange> activeRanges = [];
    if (ranges.isNotEmpty) {
      activeRanges.add(ranges.first);
      for (int i = 1; i < ranges.length; i++) {
        final last = activeRanges.last;
        final current = ranges[i];
        if (current.start <= last.end) {
          activeRanges[activeRanges.length - 1] = (start: last.start, end: (last.end > current.end ? last.end : current.end));
        } else {
          activeRanges.add(current);
        }
      }
    }

    // 2. Calculate virtual axis metrics
    const gapEquivalentWidth = 4.0; // A gap is visually as wide as 4 channels
    final totalActiveSpan = activeRanges.fold(0.0, (sum, r) => sum + (r.end - r.start));
    final totalGapSpan = (activeRanges.length > 1) ? (activeRanges.length - 1) * gapEquivalentWidth : 0.0;
    final totalVirtualSpan = totalActiveSpan + totalGapSpan;

    if (totalVirtualSpan <= 0) return; // Edge case

    // 3. Define the new non-linear x-coordinate function
    double xOf(double channel) {
      double virtualPos = 0;
      for (final range in activeRanges) {
        if (channel >= range.start && channel <= range.end) {
          virtualPos += channel - range.start;
          return chart.left + (virtualPos / totalVirtualSpan) * chart.width;
        }
        virtualPos += (range.end - range.start) + gapEquivalentWidth;
      }
      if (activeRanges.isNotEmpty && channel < activeRanges.first.start) return chart.left;
      if (activeRanges.isNotEmpty && channel > activeRanges.last.end) return chart.right;
      return -1;
    }

    // 4. Draw X-axis labels and gap indicators
    double lastLabelX = -double.infinity;
    for (int i = 0; i < activeRanges.length; i++) {
        final range = activeRanges[i];
        if (i > 0) {
            final prevRange = activeRanges[i - 1];
            final gapStartX = xOf(prevRange.end);
            final gapEndX = xOf(range.start);
            _drawText(canvas, '...', Offset((gapStartX + gapEndX) / 2 - 5, chart.bottom + 6),
                TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
        }
        final int firstCh = range.start.ceil();
        final int lastCh = range.end.floor();
        for (int ch = firstCh; ch <= lastCh; ch++) {
            bool shouldDraw = (ch % 5 == 0 && ch != 0) || ch == firstCh || ch == lastCh;
            if (shouldDraw) {
                final x = xOf(ch.toDouble());
                final label = '$ch';
                final textWidth = _measure(label, const TextStyle(fontSize: 11)).width;
                if (x > lastLabelX + textWidth + 10) {
                    canvas.drawLine(Offset(x, chart.bottom), Offset(x, chart.bottom + 4), axis);
                    _drawText(canvas, label, Offset(x - textWidth / 2, chart.bottom + 6),
                        TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
                    lastLabelX = x;
                }
            }
        }
    }

    // 5. Draw AP signals using the new xOf function
    final palette = brightness == Brightness.dark
        ? [Colors.cyanAccent, Colors.orangeAccent, Colors.pinkAccent, Colors.lightGreenAccent, Colors.amberAccent, Colors.blueAccent, Colors.limeAccent, Colors.tealAccent]
        : [Colors.blue.shade800, Colors.red.shade700, Colors.green.shade700, Colors.purple.shade700, Colors.orange.shade800, Colors.indigo.shade800, Colors.teal.shade800, Colors.brown.shade700];

    int colorIdx = 0;
    int labelIdx = 0;
    final baseY = chart.bottom - 1;

    for (final ap in aps.where((e) => e.channel > 0)) {
      final color = palette[colorIdx++ % palette.length];
      final widthCh = (ap.bandwidthMhz / 5.0);
      final slopeCh = widthCh * 0.18;
      final leftBase = ap.channel - widthCh / 2;
      final rightBase = ap.channel + widthCh / 2;
      final leftTop = leftBase + slopeCh;
      final rightTop = rightBase - slopeCh;
      final topY = yOf(ap.rssi);

      final path = Path()
        ..moveTo(xOf(leftBase), baseY)
        ..lineTo(xOf(leftTop), topY)
        ..lineTo(xOf(rightTop), topY)
        ..lineTo(xOf(rightBase), baseY)
        ..close();

      final bounds = Rect.fromLTRB(xOf(leftBase), topY, xOf(rightBase), baseY);
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.28), color.withOpacity(0.06)],
        ).createShader(bounds);
      final stroke = Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = color;

      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);

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

    _drawText(canvas, 'RSSI (dBm)', Offset(chart.left, 2), TextStyle(fontSize: 12, color: textColor));
    _drawText(canvas, '信道 (Channel)', Offset(chart.right - 110, chart.bottom + 22), TextStyle(fontSize: 12, color: textColor));
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
    _measure(s, style).paint(canvas, p);
  }
}
class AnalysisPage extends StatefulWidget {
  final String? externalUri;
  const AnalysisPage({super.key, this.externalUri}); // <-- 修改

  @override
  State<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<AnalysisPage> {
  // 状态
  bool _isMonitoring = false;
  Timer? _monitorTimer;
  String _status = '请先选择要监控的 AP';
	bool _isAiAnalyzing = false;
  String _aiAnalysisResult = '';
  // 数据
  Set<String> _selectedBssids = {};
  Map<String, List<int>> _history = {};
  Map<String, AP> _latestData = {};

  // 最多保留的数据点
  static const int _maxHistoryPoints = 150; // (150 点 * 2 秒/点 = 300秒 = 5分钟)

	@override
  void dispose() {
    _monitorTimer?.cancel();
    super.dispose();
  }
/// 单个 AP 的详情卡片
  Widget _buildApDetailCard(AP ap) {
    final vendor = lookupVendor(ap.bssid); //
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  ap.ssid.isEmpty ? '<隐藏SSID>' : ap.ssid, //
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${ap.rssi} dBm', //
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            Text(ap.bssid, style: const TextStyle(fontFamily: 'monospace')), //
            Text(vendor, style: TextStyle(color: Theme.of(context).colorScheme.secondary)),
            const Divider(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _detailChip('信道', '${ap.channel}'), //
                _detailChip('频率', '${ap.frequency} MHz'), //
                _detailChip('带宽', '${ap.bandwidthMhz} MHz'), //
                _detailChip('标准', ap.standard, flex: 2), //
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailChip(String label, String value, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
// (!!) 新增：执行 AI 分析
  Future<void> _runAiAnalysis(HistoryRecord record) async { //
    setState(() {
      _isAiAnalyzing = true;
      _aiAnalysisResult = '正在分析中...';
    });
    
    // 自动滚动到 AI 卡片
    final ctx = _aiCardKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300));
    }

    // 1. 获取 AI 配置
    final apiKey = settingsService.apiKey;
    final apiEndpoint = settingsService.apiEndpoint;
    if (apiKey.isEmpty) {
      setState(() {
        _isAiAnalyzing = false;
        _aiAnalysisResult = '分析失败：请先在“设置”页面配置 API Key。';
      });
      return;
    }

    // 2. 获取系统语言
    final lang = View.of(context).platformDispatcher.locale.languageCode;




    // 4. 将 payload 转为 JSON 字符串
    final historyJson = jsonEncode(record.payload);

    // 5. 调用服务
    final result = await AiAnalyzerService.analyze(
      historyPayloadJson: historyJson,
      apiKey: apiKey,
      apiEndpoint: apiEndpoint,
      languageCode: lang,
			modelName: settingsService.modelName,
    );

    if (!mounted) return;
    setState(() {
      _isAiAnalyzing = false;
      _aiAnalysisResult = result;
    });
  }
  // (!!) 新增：从历史记录加载的逻辑
  Future<void> _loadFromHistory() async {
    // 检查历史文件 URI 是否存在 (从 HomePage 传来)
    if (widget.externalUri == null || widget.externalUri!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在"概览"页设定一个导出文件')),
      );
      return;
    }

    // 推入 HistoryPage，并等待它返回一个 HistoryRecord
    final result = await Navigator.of(context).push<HistoryRecord>(
      MaterialPageRoute(
        builder: (_) => HistoryPage(
          externalUri: widget.externalUri,
          isSelectionMode: true, // (!!) 告诉 HistoryPage 我们是来选条目的
        ),
      ),
    );

    if (!mounted || result == null) return; // 用户取消了选择

    // --- 开始处理返回的 HistoryRecord ---
    // HistoryRecord.payload 已经是解析过的 Map
    final payload = result.payload;
    if (payload['results'] is! List) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('历史记录格式错误：未找到 "results" 列表')),
      );
      return;
    }

    final List<dynamic> rawAps = payload['results'];
    if (rawAps.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('此历史记录中没有 AP 数据')),
      );
      return;
    }

    // 重置当前状态
    final newSelectedBssids = <String>{};
    final newHistory = <String, List<int>>{};
    final newLatestData = <String, AP>{};

    int parsedCount = 0;
    for (final rawAp in rawAps.whereType<Map>()) {
      try {
        //
        final ap = _parseApFromJson(rawAp as Map<String, dynamic>);
        newSelectedBssids.add(ap.bssid);
        // (!!) 核心：将历史数据作为第一个点 (t=0) 添加
        newHistory[ap.bssid] = [ap.rssi];
        newLatestData[ap.bssid] = ap;
        parsedCount++;
      } catch (e) {
        InAppLog.d('Failed to parse AP from history: $e');
      }
    }

    if (parsedCount == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('解析历史数据失败')),
      );
      return;
    }

    // 提交新状态
    setState(() {
      _selectedBssids = newSelectedBssids;
      _history = newHistory;
      _latestData = newLatestData;
      _status = '已从历史载入 $parsedCount 个 AP';
			_isAiAnalyzing = false;
      _aiAnalysisResult = '';
    });
		_runAiAnalysis(result);
  }

  // (!!) 新增：AP.toJson() 的逆向操作，用于解析历史
  AP _parseApFromJson(Map<String, dynamic> m) {
    final freq = (m['frequency_mhz'] as num?)?.toInt() ?? 0;
    final bw = (m['bandwidth_mhz'] as num?)?.toInt() ?? 20;
    final caps = (m['capabilities'] as String?) ?? '';
    
    // 优先使用历史记录中已存的 standard 字符串
    final std = m['standard'] as String? ??
        determineWifiStandard( // 否则重新计算
          code: (m['wifiStandardCode'] as num?)?.toInt(),
          capabilities: caps,
          freq: freq,
          bw: bw,
        );

    return AP( //
      ssid: m['ssid'] as String? ?? '',
      bssid: (m['bssid'] as String? ?? '').toLowerCase(),
      rssi: (m['rssi'] as num?)?.toInt() ?? -100,
      frequency: freq,
      channel: (m['channel'] as num?)?.toInt() ?? freqToChannel(freq), //
      bandwidthMhz: bw,
      standard: std,
      capabilities: caps,
      wifiStandardCode: (m['wifiStandardCode'] as num?)?.toInt(),
      wifiStandardRaw: m['wifiStandardRaw'] as String?,
      channelWidthRaw: m['channelWidthRaw'] as String?,
      centerFreq0: (m['centerFreq0'] as num?)?.toInt(),
      centerFreq1: (m['centerFreq1'] as num?)?.toInt(),
    );
  }
	
	
// (!!) 新增：构建图例项的辅助方法
  List<Widget> _buildLegendItems(Brightness brightness) {
    final palette = brightness == Brightness.dark
        ? SignalChartPainter._darkColors
        : SignalChartPainter._lightColors;
    int colorIdx = 0;
    
    return _history.keys.map((bssid) {
      final color = palette[colorIdx++ % palette.length];
      final ap = _latestData[bssid];
      final label = ap?.ssid.isEmpty == false
          ? ap!.ssid
          : (ap?.bssid ?? bssid);

      return Chip(
        avatar: CircleAvatar(
          backgroundColor: color,
          radius: 6, // 小色块
        ),
        label: Text(
          label,
          style: const TextStyle(fontSize: 12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        labelPadding: const EdgeInsets.only(left: 4),
        side: BorderSide.none,
        backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
      );
    }).toList();
  }
  /// 弹出 AP 选择对话框
  Future<void> _showSelectApDialog() async {
    setState(() => _status = '正在扫描可用 AP...');
    List<AP> allAps = [];
    try {
      final raw = await _wifiStdChannel.invokeMethod<List<dynamic>>('scanAndGet') ?? const [];
      allAps = _mapArkListToAp(raw); // 使用 main.dart 已有的 _mapArkListToAp
      setState(() => _status = '请选择：');
    } catch (e) {
      setState(() => _status = '扫描失败: $e');
      return;
    }

    if (!mounted) return;

    // 使用一个临时的 Set 来管理对话框内的勾选状态
    final tempSelected = Set<String>.from(_selectedBssids);

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogContext, dialogSetState) {
            return AlertDialog(
              title: const Text('选择要监控的 AP'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  itemCount: allAps.length,
                  itemBuilder: (_, i) {
                    final ap = allAps[i];
                    final isSelected = tempSelected.contains(ap.bssid);
                    return CheckboxListTile(
                      title: Text(ap.ssid.isEmpty ? '<隐藏SSID>' : ap.ssid),
                      subtitle: Text(ap.bssid),
                      value: isSelected,
                      onChanged: (val) {
                        dialogSetState(() {
                          if (val == true) {
                            tempSelected.add(ap.bssid);
                          } else {
                            tempSelected.remove(ap.bssid);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );

    // 如果用户点击了“确定”
    if (result == true) {
      setState(() {
        _selectedBssids = tempSelected;
        _status = '已选择 ${_selectedBssids.length} 个 AP';
        _initializeHistory();
      });
    }
  }

  /// 根据新的选择，初始化数据结构
  void _initializeHistory() {
    _history.clear();
    _latestData.clear();
    for (final bssid in _selectedBssids) {
      _history[bssid] = [];
    }
  }

  /// 清空所有历史数据
  void _clearHistory() {
    setState(() {
      _initializeHistory();
      _status = '已清空历史，共 ${_selectedBssids.length} 个 AP';
    });
  }

  /// 开始监控
  void _startMonitoring() {
    if (_selectedBssids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择要监控的 AP')),
      );
      return;
    }
    _monitorTimer?.cancel(); // 先停止旧的
    _monitorTimer = Timer.periodic(const Duration(seconds: 2), _tick);
    setState(() {
      _isMonitoring = true;
      _status = '监控中...';
    });
  }

  /// 停止监控
  void _stopMonitoring() {
    _monitorTimer?.cancel();
    setState(() {
      _isMonitoring = false;
      _status = '监控已停止';
    });
  }

  /// Timer 的回调，核心扫描逻辑
  Future<void> _tick(Timer t) async {
    if (!_isMonitoring) {
      t.cancel();
      return;
    }

    List<AP> currentAps = [];
    try {
      final raw = await _wifiStdChannel.invokeMethod<List<dynamic>>('scanAndGet') ?? const [];
      currentAps = _mapArkListToAp(raw);
    } catch (e) {
      // 扫描失败，也算一个数据点（-100）
      InAppLog.d('Analysis tick scan error: $e');
    }

    // 将列表转为 Map 方便查找
    final apMap = <String, AP>{for (final ap in currentAps) ap.bssid: ap};

    setState(() {
      for (final bssid in _selectedBssids) {
        final ap = apMap[bssid];
        final rssi = ap?.rssi ?? -100; // 如果 AP 消失了，信号强度记为 -100

        // 添加新数据
        final historyList = _history[bssid] ?? [];
        historyList.add(rssi);

        // 裁剪旧数据
        if (historyList.length > _maxHistoryPoints) {
          _history[bssid] = historyList.sublist(historyList.length - _maxHistoryPoints);
        } else {
          _history[bssid] = historyList;
        }


        // 更新最新详情
        if (ap != null) {
          _latestData[bssid] = ap;
        }
      }
    });
  }

@override
  Widget build(BuildContext context) {
    // (!!) 1. 用 SingleChildScrollView 包裹
    return SingleChildScrollView(
      child: Column(
        children: [
          // 1. 控制栏 (保持不变)
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                Row(
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.playlist_add_check),
                      label: Text('选择 AP (${_selectedBssids.length})'),
                      onPressed: _isMonitoring ? null : _showSelectApDialog,
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.history_edu),
                      label: const Text('从历史载入'),
                      onPressed: _isMonitoring ? null : _loadFromHistory,
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        foregroundColor: Theme.of(context).colorScheme.onSecondary,
                      ),
                    ),
                    const Spacer(),
                    IconButton.filled(
                      icon: Icon(_isMonitoring ? Icons.stop : Icons.play_arrow),
                      tooltip: _isMonitoring ? '停止监控' : '开始监控',
                      onPressed: _isMonitoring ? _stopMonitoring : _startMonitoring,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.clear_all),
                      tooltip: '清空历史',
                      onPressed: _isMonitoring ? null : _clearHistory,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _status,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),

          // 2. 图表
          // (!!) 2. 移除 Expanded，替换为 SizedBox
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SizedBox(
              height: 300, // (!!) 3. 给予固定的图表高度
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: CustomPaint(
                    painter: SignalChartPainter(
                      history: _history,
                      brightness: Theme.of(context).brightness,
                      maxHistoryPoints: _maxHistoryPoints,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),

          // 3. 弹性图例 (保持不变)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8.0, // 水平间距
              runSpacing: 4.0, // 垂直间距
              children: _buildLegendItems(Theme.of(context).brightness),
            ),
          ),

          // 4. 详情卡片
          // (!!) 4. 移除 Expanded，添加 shrinkWrap 和 physics
          ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shrinkWrap: true, // (!!) 5. 让 ListView 根据内容自适应高度
            physics: const NeverScrollableScrollPhysics(), // (!!) 6. 禁用内部滚动
            children: _latestData.values.map((ap) {
              return _buildApDetailCard(ap);
            }).toList(),
          ),
					// (!!) 5. 新增 AI 分析结果卡片
          if (_aiAnalysisResult.isNotEmpty || _isAiAnalyzing)
            Padding(
              key: _aiCardKey, // 绑定 GlobalKey 以便滚动
              padding: const EdgeInsets.all(12.0),
              child: Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.auto_awesome, color: Colors.blue),
                          const SizedBox(width: 8),
                          Text(
                            'AI 网络分析',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_isAiAnalyzing)
                        const Center(child: CircularProgressIndicator())
                      else
                        SelectableText(_aiAnalysisResult),
                    ],
                  ),
                ),
              ),
            ),
          
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}


// ===================================================================
// (!!) 新增：信号分析页的折线图
// ===================================================================

class SignalChartPainter extends CustomPainter {
  final Map<String, List<int>> history;
  final Brightness brightness;
	final int maxHistoryPoints;

  SignalChartPainter({
    required this.history,
    required this.brightness,
		required this.maxHistoryPoints,
  });

  static const int minRssi = -100;
  static const int maxRssi = -30;

  // 颜色循环列表
	static const List<Color> _darkColors = [
    Colors.cyanAccent, Colors.orangeAccent, Colors.pinkAccent,
    Colors.lightGreenAccent, Colors.amberAccent, Colors.blueAccent,
    Colors.limeAccent, Colors.tealAccent,
  ];
  static const List<Color> _lightColors = [
    Colors.blue, Colors.red, Colors.green,
    Colors.purple, Colors.orange, Colors.indigo,
    Colors.teal, Colors.brown,
  ];
  
  // 缓存 TextPainter
  final Map<String, TextPainter> _labelCache = {};

  TextPainter _measure(String s, TextStyle style, {double maxWidth = 200}) {
    // 简单缓存
    if (_labelCache.containsKey(s)) return _labelCache[s]!;
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(minWidth: 0, maxWidth: maxWidth);
    _labelCache[s] = tp;
    return tp;
  }

  void _drawText(Canvas canvas, String s, Offset p, TextStyle style) {
    _measure(s, style).paint(canvas, p);
  }
@override
  void paint(Canvas canvas, Size size) {
    // (!!) 恢复底部 padding，因为图例移出去了
    final padding = const EdgeInsets.fromLTRB(48, 16, 12, 12); 
    final chart = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.left - padding.right,
      size.height - padding.top - padding.bottom,
    );

    final textColor = brightness == Brightness.dark ? Colors.white : Colors.black87;
    final gridColor = (brightness == Brightness.dark ? Colors.white70 : Colors.black87).withOpacity(0.22);
    final axisColor = gridColor.withOpacity(0.55);

    // --- 绘制 Y 轴 (RSSI) ---
    final grid = Paint()
      ..style = PaintingStyle.stroke..strokeWidth = 0.5..color = gridColor;
    const rows = 7; // -100, -90, ..., -30
    for (int i = 0; i <= rows; i++) {
      final y = chart.top + i * chart.height / rows;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }
    final axis = Paint()
      ..style = PaintingStyle.stroke..strokeWidth = 1..color = axisColor;
    canvas.drawRect(chart, axis); // 绘制边框

    double yOf(int rssi) {
      final rr = rssi.clamp(minRssi, maxRssi).toDouble();
      final t = (rr - minRssi) / (maxRssi - minRssi); // 0.0 -> 1.0
      return chart.bottom - t * chart.height;
    }
    for (int r = -100; r <= -30; r += 10) {
      final y = yOf(r);
      _drawText(canvas, '$r dBm', Offset(padding.left - 44, y - 7),
          TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
    }
    // [ ... Y 轴绘制结束 ... ]


    // --- 绘制 X 轴 (时间) ---
    final palette = brightness == Brightness.dark ? _darkColors : _lightColors;
    int colorIdx = 0;

    int maxLen = maxHistoryPoints; // 使用传入的 maxHistoryPoints
    if (history.values.isNotEmpty) {
      final currentMax = history.values.map((e) => e.length).reduce((a, b) => a > b ? a : b);
      if (currentMax > maxLen) maxLen = currentMax;
    }
    if (maxLen <= 1) return; // 至少需要2个点才能画线

    final bssids = history.keys.toList();
    
    // (!!) 图例绘制代码已被移除 (!!)

    // --- 绘制折线 ---
    colorIdx = 0; // 重置颜色索引
    for (final bssid in bssids) {
      final color = palette[colorIdx++ % palette.length];
      final points = history[bssid]!;
      if (points.length < 2) continue;

      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = color;

      // 绘制平滑曲线 (Cubic Bezier Spline)
      final List<Offset> offsetPoints = [];
      final int startIdx = (points.length < maxLen) ? (maxLen - points.length) : 0;
      for (int i = 0; i < points.length; i++) {
        final x = chart.left + ((i + startIdx) / (maxLen - 1)) * chart.width;
        final y = yOf(points[i]);
        offsetPoints.add(Offset(x, y));
      }

      final path = Path();
      path.moveTo(offsetPoints[0].dx, offsetPoints[0].dy);

      for (int i = 0; i < offsetPoints.length - 1; i++) {
        final p_1 = (i == 0) ? offsetPoints[i] : offsetPoints[i - 1];
        final p0 = offsetPoints[i];
        final p1 = offsetPoints[i + 1];
        final p2 = (i >= offsetPoints.length - 2) ? p1 : offsetPoints[i + 2];

        final cp1x = p0.dx + (p1.dx - p_1.dx) / 6.0;
        final cp1y = p0.dy + (p1.dy - p_1.dy) / 6.0;
        final cp2x = p1.dx - (p2.dx - p0.dx) / 6.0;
        final cp2y = p1.dy - (p2.dy - p0.dy) / 6.0;

        path.cubicTo(cp1x, cp1y, cp2x, cp2y, p1.dx, p1.dy);
      }
      
      canvas.drawPath(path, stroke);
    }
  }

	@override
  bool shouldRepaint(covariant SignalChartPainter old) {
    // 优化：只有在数据或主题变化时才重绘
    return old.history != history ||
        old.brightness != brightness ||
        old.maxHistoryPoints != maxHistoryPoints; // Also check if max points changed
  }
}


// ===================================================================
// (!!) 新增：MAC 厂商查询工具
// ===================================================================

String lookupVendor(String bssid) {
  // 代理到新的 VendorDb 类
  return VendorDb.lookup(bssid);
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}
class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _apiEndpointCtrl;
  late final TextEditingController _modelCtrl;

  @override
  void initState() {
    super.initState();
    _apiKeyCtrl = TextEditingController(text: settingsService.apiKey);
    // (!!) 从 apiBaseDomain 初始化
    _apiEndpointCtrl = TextEditingController(text: settingsService.apiBaseDomain); 
    _modelCtrl = TextEditingController(text: settingsService.modelName);
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _apiEndpointCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  void _saveSettings() {
    FocusScope.of(context).unfocus();
    settingsService.setAiConfig(
      _apiKeyCtrl.text.trim(),
      _apiEndpointCtrl.text.trim(), // (!!) 传递的是 baseDomain
      _modelCtrl.text.trim(),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        // --- 外观设置 ---
        Text('外观', style: Theme.of(context).textTheme.titleSmall),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: ListenableBuilder(
              listenable: settingsService,
              builder: (context, child) {
                return Column(
                  children: [
                    RadioListTile<ThemeMode>(
                      title: const Text('跟随系统'),
                      value: ThemeMode.system,
                      groupValue: settingsService.themeMode,
                      onChanged: (v) => settingsService.setThemeMode(v!),
                    ),
                    RadioListTile<ThemeMode>(
                      title: const Text('浅色模式'),
                      value: ThemeMode.light,
                      groupValue: settingsService.themeMode,
                      onChanged: (v) => settingsService.setThemeMode(v!),
                    ),
                    RadioListTile<ThemeMode>(
                      title: const Text('深色模式'),
                      value: ThemeMode.dark,
                      groupValue: settingsService.themeMode,
                      onChanged: (v) => settingsService.setThemeMode(v!),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 20),

        // --- AI 分析设置 ---
        Text('AI 分析 (OpenAI 格式)', style: Theme.of(context).textTheme.titleSmall),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                TextField(
                  controller: _apiEndpointCtrl, // (!!) 绑定到 base domain
                  decoration: const InputDecoration(
                    labelText: 'API 基础域名', // (!!) 修改标签
                    border: OutlineInputBorder(),
                    // (!!) 修改辅助文本
                    helperText: '例如: api.openai.com\n将自动补全为 https://.../v1/chat/completions', 
                    hintText: 'api.openai.com',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _modelCtrl,
                  decoration: const InputDecoration(
                    labelText: '模型名称',
                    border: OutlineInputBorder(),
                    helperText: '例如: gpt-4o-mini',
                    hintText: 'gpt-4o-mini',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _apiKeyCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API Key (sk-...)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _saveSettings,
                  child: const Text('保存 AI 设置'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        // --- 关于 ---
        Text('关于', style: Theme.of(context).textTheme.titleSmall),
        Card(
          child: ListTile(
            title: const Text('关于 Wi-Fi Handler'),
            leading: const Icon(Icons.info_outline),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AboutPage()),
              );
            },
          ),
        ),
      ],
    );
  }
}
// ===================================================================
// (!!) 新增：关于页面
// ===================================================================

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('关于'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          ListTile(
            title: const Text('应用名称'),
            subtitle: const Text('Wi-Fi Handler (Flutter/Harmony)'),
            leading: Icon(
              Icons.wifi,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const ListTile(
            title: Text('版本'),
            subtitle: Text('1.0.0 (Dev)'),
            leading: Icon(Icons.new_releases_outlined),
          ),
          const ListTile(
            title: Text('Author'),
            subtitle: Text('来自XDU的三名学生'),
            leading: Icon(Icons.person_outline),
          ),
        ],
      ),
    );
  }
}