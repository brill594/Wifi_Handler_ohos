import { FlutterAbility, FlutterEngine, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import wifiManager from '@ohos.wifiManager';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import type Want from '@ohos.app.ability.Want';
import { BusinessError } from '@ohos.base';

type Throwable =
  | Error
  | BusinessError
  | string
  | number
  | boolean
  | object
  | null
  | undefined;

// 单独声明用到的结构，避免对象字面量当类型
interface HasMessage { message?: string }
interface HasCode { code: number }

function normalizeError(e: Throwable): Error {
  if (e instanceof Error) return e;

  // BusinessError（或长得像它的对象）
  try {
    const be = e as object | null;
    if (be && typeof be === 'object') {
      const hc = be as Partial<HasCode>;
      if (typeof hc.code === 'number') {
        const hm = be as HasMessage;
        const msg = typeof hm.message === 'string'
          ? hm.message
          : `BusinessError code=${hc.code}`;
        return new Error(msg);
      }
    }
  } catch { /* 忽略结构探测失败 */ }

  // 3) 普通字符串/数字/对象 → 全部转成字符串
  return new Error(String(e));
}

let fileOpsCh: MethodChannel | undefined;

function emitLog(msg: string) {
  try {
    fileOpsCh?.invokeMethod('onLog', { t: Date.now(), msg });
  } catch (_) {
    // 忽略回推失败
  }
}

// 只声明我们要的签名：返回 string | null | undefined
interface MethodCallStrArg {
  argument?: (key: string) => string | null | undefined;
}
type ArgFn = (key: string) =>
string | number | boolean | object | null | undefined;

interface HasArgument {
  argument?: ArgFn;
}

function getStrArg(call: MethodCall, key: string, defVal: string): string {
  const fn: ArgFn | undefined = (call as HasArgument).argument;
  const v = fn ? fn(key) : undefined;
  return typeof v === 'string' ? v : defVal;
}


// ------------------ 工具函数（无 any/unknown） ------------------
function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
    else if ((c & 0xFC00) === 0xD800 && i + 1 < s.length) {
      const c2 = s.charCodeAt(++i);
      const u = 0x10000 + ((c & 0x3FF) << 10) + (c2 & 0x3FF);
      out.push(0xF0 | (u >> 18), 0x80 | ((u >> 12) & 0x3F), 0x80 | ((u >> 6) & 0x3F), 0x80 | (u & 0x3F));
    } else {
      out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
    }
  }
  return new Uint8Array(out);
}
function delay(ms: number): Promise<void> {
  return new Promise((res) => setTimeout(res, ms));
}

// ------------------ Wi-Fi 类型 ------------------

/* ---------- 类型（对应你贴的 WifiScanInfo 表） ---------- */
interface WifiScanInfo {
  ssid?: string;
  bssid?: string;
  bssidType?: number;               // DeviceAddressType（用 number 承接，避免引入枚举）
  capabilities?: string;
  securityType?: number;            // WifiSecurityType（number）
  rssi?: number;                    // dBm
  band?: number;                    // 1=2.4G, 2=5G（6G 在部分机型也返回 3）
  frequency?: number;               // MHz
  channelWidth?: number;            // WifiChannelWidth（number）
  centerFrequency0?: number;        // MHz
  centerFrequency1?: number;        // MHz
  timestamp?: number;
  supportedWifiCategory?: number;   // WifiCategory（API12+；number）
}

/* Dart 侧期望的输出结构（保持你现有的 keys） */
interface WifiStdOut {
  ssid: string;
  bssid: string;
  level: number;
  frequency: number;
  capabilities: string;
  wifiStandardCode: number | null;  // 用 supportedWifiCategory 近似承接
  wifiStandardRaw: string | null;   // 直接把 code 转字符串
  channelWidthCode: number | null;  // 0/1/2/3/4/5…
  channelWidthRaw: string | null;   // 无官方 name 时就传 null
  centerFreq0: number | null;
  centerFreq1: number | null;
}

/* ---------- 小工具 ---------- */
/* 字段对齐与容错 */
/* WifiCategory -> Android-like wifiStandard code */
function mapWifiCategoryToStdCode(cat: number | null): number | null {
  // Harmony: 1=DEFAULT(≤WiFi6), 2=WiFi6, 3=WiFi6+, 4=WiFi7, 5=WiFi7+
  if (cat === 4 || cat === 5) return 7;   // 802.11be (Wi-Fi 7 / 7+)
  if (cat === 2 || cat === 3) return 6;   // 802.11ax (Wi-Fi 6 / 6+)
  // 其余（1 或 null）都当作未知/旧标准，让 Dart 继续走 capabilities 兜底
  return null;
}

/* 打包输出（替换你现在的 packOut 同名部分） */
function packOut(it: WifiScanInfo): WifiStdOut {
  const ssid = it.ssid ?? '';
  const bssid = (it.bssid ?? '').toLowerCase();
  const level = (it.rssi ?? -100) as number;
  const frequency = (it.frequency ?? 0) as number;
  const capabilities = it.capabilities ?? '';

  const cat: number | null = (it.supportedWifiCategory ?? null) as number | null;
  const wifiStandardCode = mapWifiCategoryToStdCode(cat);     // ← 关键：映射后给 Dart
  const wifiStandardRaw = cat !== null ? `WIFI_CATEGORY_${cat}` : null;

  const channelWidthCode = (it.channelWidth ?? null) as number | null;
  const channelWidthRaw = null;

  const centerFreq0 = (it.centerFrequency0 ?? null) as number | null;
  const centerFreq1 = (it.centerFrequency1 ?? null) as number | null;

  return {
    ssid, bssid, level, frequency, capabilities,
    wifiStandardCode, wifiStandardRaw,
    channelWidthCode, channelWidthRaw,
    centerFreq0, centerFreq1
  };
}


/* ---------- 扫描实现：带节流与去重 ---------- */
let lastScanAt = 0;

/** 触发扫描（≥3s 节流）并读取结果 */
export async function scanAndGet(): Promise<WifiStdOut[]> {
  const now = Date.now();
  const needScan = (now - lastScanAt) >= 3000;
  if (needScan) {
    lastScanAt = now;
    try {
      try {
        const active = wifiManager.isWifiActive();
        if (!active) { try { } catch {} }
      } catch {}
      wifiManager.scan();
    } catch (e) {
      console.warn('[wifi] scan() failed:', normalizeError(e).message);
    }
  }
  await delay(needScan ? 1300 : 200);
  return getScanListUnique();
}

/** 仅获取（不触发扫描），用于“获取标准列表” */
export async function getScanStandards(): Promise<WifiStdOut[]> {
  return getScanListUnique();
}

/* 读取并按 BSSID 去重 */
function getScanListUnique(): WifiStdOut[] {
  let list: WifiScanInfo[] = [];
  try {
    list = wifiManager.getScanInfoList();
  } catch (e) {
    console.error('[wifi] getScanInfoList failed:', normalizeError(e).message);
    list = [];
  }
  const seen = new Set<string>();
  const out: WifiStdOut[] = [];
  for (const it of list) {
    const b = (it.bssid ?? '').toLowerCase();
    if (!b || seen.has(b)) continue;
    seen.add(b);
    out.push(packOut(it));
  }
  return out;
}


// ------------------ 文件保存/打开（OH 5.0+ 公共 API） ------------------


async function saveJsonToDownloads(ctx: common.UIAbilityContext, fileName: string, text: string): Promise<string> {
  emitLog('ArkTS: picker.construct');
  const view = new picker.DocumentViewPicker(ctx);

  const opts = new picker.DocumentSaveOptions();
  opts.newFileNames = [fileName];
  opts.fileSuffixChoices = ['json'];

  emitLog('ArkTS: picker.save()');
  const uris: string[] = await view.save(opts);
  emitLog(`ArkTS: picker.ret ${JSON.stringify(uris)}`);
  if (!uris || uris.length === 0) throw new Error('canceled');

  const target: string = uris[0];
  const data = utf8Encode(text);

  let fh: fs.File | null = null;
  try {
    emitLog(`ArkTS: fs.open ${target}`);
    fh = await fs.open(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    emitLog(`ArkTS: fs.open ok fd=${fh.fd}`);

    emitLog(`ArkTS: fs.write ${data.byteLength}B`);
    await fs.write(fh.fd, data);
    emitLog('ArkTS: fs.write ok');

    return target;
  } catch (e) {
    const err = normalizeError(e);
    emitLog(`ArkTS: fs error ${err.message}`); // 你自己的 onLog 回推
    throw err;                                 // ✅ 只抛标准 Error
  } finally {
    if (fh) {
      try {
        await fs.close(fh.fd);
      } catch {
      }
    }
  }
}



async function openUri(ctx: common.UIAbilityContext, target: string): Promise<void> {
  const want: Want = {
    action: 'ohos.want.action.viewData',
    uri: target,
    type: 'application/json',
  };
  await ctx.startAbility(want);
}

// ------------------ 单一 EntryAbility（两个通道） ------------------
export default class EntryAbility extends FlutterAbility {
  private wifiCh?: MethodChannel;
  private fileCh?: MethodChannel;

  configureFlutterEngine(engine: FlutterEngine): void {
    super.configureFlutterEngine(engine);
    console.info('[EntryAbility] configureFlutterEngine');
    emitLog('ArkTS: configureFlutterEngine');

    this.fileCh = new MethodChannel(engine.dartExecutor, 'file_ops');
    fileOpsCh = this.fileCh;               // 让 emitLog 可用
    emitLog('ArkTS: file_ops registered');

    this.fileCh.setMethodCallHandler({
      onMethodCall: async (call: MethodCall, result: MethodResult) => {
        emitLog(`ArkTS<-Dart ${call.method}`);
        try {
          if (call.method === 'ping') { result.success(true); return; }

          if (call.method === 'saveToDownloads') {
            const fileName = getStrArg(call, 'fileName', 'wifi_scans.json');
            const text = getStrArg(call, 'text', '');
            result.success({ ok: true, pending: true }); // 立即返回
            emitLog('ArkTS: start save flow');

            (async () => {
              try {
                emitLog('ArkTS: open picker');
                const uri = await saveJsonToDownloads(this.context as common.UIAbilityContext, fileName, text);
                emitLog(`ArkTS: got uri = ${uri}`);

                await this.fileCh?.invokeMethod('onSaved', { ok: true, uri });
                emitLog('ArkTS: onSaved(ok) sent');
              } catch (e) {
                await this.fileCh?.invokeMethod('onSaved', { ok: false, message: String(e) });
                emitLog(`ArkTS: onSaved(fail) ${String(e)}`);
              }
            })();
            return;
          }

          if (call.method === 'openUri') {
            const target = getStrArg(call, 'uri', '');
            if (!target) { result.success({ ok: false, message: 'empty uri' }); return; }
            emitLog(`ArkTS: openUri ${target}`);
            try {
              await openUri(this.context as common.UIAbilityContext, target);
              result.success({ ok: true });
              emitLog('ArkTS: openUri ok');
            } catch (e) {
              const err = normalizeError(e);
              result.success({ ok: false, message: err.message });
            }
            return;
          }

          result.error('404', `No such method: ${call.method}`, null);
          emitLog(`ArkTS: 404 ${call.method}`);
        } catch (e) {
          result.error('500', String(e), null);
          emitLog(`ArkTS: 500 ${String(e)}`);
        }
      }
    });
    /* -------- wifi_std（需要补回） -------- */
    this.wifiCh = new MethodChannel(engine.dartExecutor, 'wifi_std');
    emitLog('ArkTS: wifi_std registered');

    this.wifiCh.setMethodCallHandler({
      onMethodCall: async (call: MethodCall, result: MethodResult) => {
        emitLog(`ArkTS<-Dart [wifi] ${call.method}`);
        try {
          if (call.method === 'ping') { result.success({ ok: true, from: 'arkts:wifi' }); return; }
          if (call.method === 'saveToDownloads') {
            try {
              const fileName = getStrArg(call, 'fileName', 'wifi_scans.json');
              const text = getStrArg(call, 'text', '');
              result.success({ ok: true, pending: true }); // 立即返回
              (async () => {
                try {
                  const uri = await saveJsonToDownloads(this.context as common.UIAbilityContext, fileName, text);
                  await this.fileCh?.invokeMethod('onSaved', { ok: true, uri });
                } catch (e) {
                  await this.fileCh?.invokeMethod('onSaved', { ok: false, message: String(e) });
                }
              })();
            } catch (e) {
              result.error('500', String(e), null);
            }
            return;
          }

          if (call.method === 'scanAndGet') {
            try {
              const data = await scanAndGet();     // 你上面定义的函数
              result.success(data);
            } catch (e) {
              const err = normalizeError(e);
              result.error('500', err.message, null);
            }
            return;
          }

          if (call.method === 'getScanStandards') {
            try {
              const data = await getScanStandards(); // 你上面定义的函数
              result.success(data);
            } catch (e) {
              const err = normalizeError(e);
              result.error('500', err.message, null);
            }
            return;
          }

          result.error('404', `No such method: ${call.method}`, null);
        } catch (e) {
          const err = normalizeError(e);
          result.error('500', err.message, null);
        }
      }
    });
  }
}

