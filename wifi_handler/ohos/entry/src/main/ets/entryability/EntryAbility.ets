import { FlutterAbility, FlutterEngine, MethodCall, MethodResult, MethodChannel } from '@ohos/flutter_ohos';
import wifiManager from '@ohos.wifiManager';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import type Want from '@ohos.app.ability.Want';
import { BusinessError } from '@ohos.base';
import window from '@ohos.window';
import type { UIContext } from '@ohos.arkui.UIContext';

const HISTORY_FILE = 'history.jsonl';

type HistVal = string | number | boolean | null;
export interface HistoryRowText { t: number; payload: string; }


// ==== UTF-8 编解码，不依赖 @ohos.util ====
function encodeUtf8(str: string): Uint8Array {
  const bytes: number[] = [];
  for (const ch of Array.from(str)) {               // 处理代理对
    const cp = ch.codePointAt(0)!;
    if (cp <= 0x7F) {
      bytes.push(cp);
    } else if (cp <= 0x7FF) {
      bytes.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
    } else if (cp <= 0xFFFF) {
      bytes.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
    } else {
      bytes.push(
        0xF0 | (cp >> 18),
        0x80 | ((cp >> 12) & 0x3F),
        0x80 | ((cp >> 6) & 0x3F),
        0x80 | (cp & 0x3F)
      );
    }
  }
  return new Uint8Array(bytes);
}

function decodeUtf8(bytes: Uint8Array): string {
  let i = 0, out = '';
  while (i < bytes.length) {
    const b1 = bytes[i++];
    if ((b1 & 0x80) === 0) { out += String.fromCodePoint(b1); continue; }
    const b2 = bytes[i++] & 0x3F;
    if ((b1 & 0xE0) === 0xC0) {
      const cp = ((b1 & 0x1F) << 6) | b2;
      out += String.fromCodePoint(cp);
      continue;
    }
    const b3 = bytes[i++] & 0x3F;
    if ((b1 & 0xF0) === 0xE0) {
      const cp = ((b1 & 0x0F) << 12) | (b2 << 6) | b3;
      out += String.fromCodePoint(cp);
      continue;
    }
    const b4 = bytes[i++] & 0x3F;
    const cp = ((b1 & 0x07) << 18) | (b2 << 12) | (b3 << 6) | b4;
    out += String.fromCodePoint(cp);
  }
  return out;
}

function preview(s: string, maxLen: number): string {
  const n = s.length <= maxLen ? s.length : maxLen;
  return s.slice(0, n)
    .replace(/\n/g, '\\n')
    .replace(/\r/g, '\\r')
    .replace(/\t/g, '\\t');
}

async function writeBytes(fd: number, buf: Uint8Array): Promise<number> {
  return await fs.write(fd, buf.buffer, {
    offset: buf.byteOffset,
    length: buf.byteLength,
  });
}

function fmtBytes(n: number): string {
  if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(2)}MB`;
  if (n >= 1 << 10) return `${(n / (1 << 10)).toFixed(2)}KB`;
  return `${n}B`;
}
interface SaveSession { fd: number; uri: string; bytes: number; chunks: number; t0: number; }
const saveSessions = new Map<number, SaveSession>();
let nextSid = 1;

function historyPath(ctx: common.Context): string {
  return `${ctx.filesDir}/${HISTORY_FILE}`;
}
async function ensureFile(ctx: common.Context) {
  try { await fs.access(historyPath(ctx)); }
  catch { const fh = await fs.open(historyPath(ctx), fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE); await fs.close(fh); }
}

function splitTopLevelObjects(input: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = -1;
  let inStr = false;
  let esc = false;
  for (let i = 0; i < input.length; i++) {
    const ch = input.charAt(i);
    if (inStr) {
      if (esc) { esc = false; }
      else if (ch === '\\') { esc = true; }
      else if (ch === '"') { inStr = false; }
      continue;
    }
    if (ch === '"') { inStr = true; continue; }
    if (ch === '{') { if (depth === 0) start = i; depth++; continue; }
    if (ch === '}') {
      if (depth > 0) depth--;
      if (depth === 0 && start >= 0) {
        out.push(input.slice(start, i + 1));
        start = -1;
      }
    }
  }
  return out;
}

// ===== 辅助：从单个 JSON 片段中提取时间戳（优先 "t":123，其次 "timestamp":"..."）=====
function tryParseEpochMsFromSegment(seg: string): number {
  // "t": 123456
  let p = seg.indexOf('"t"');
  if (p >= 0) {
    const colon = seg.indexOf(':', p);
    if (colon >= 0) {
      let j = colon + 1;
      while (j < seg.length && (seg.charAt(j) === ' ' || seg.charAt(j) === '\t')) j++;
      let k = j;
      while (k < seg.length) {
        const c = seg.charCodeAt(k);
        if (c < 48 || c > 57) break; // 非 0-9
        k++;
      }
      if (k > j) {
        const v = Number(seg.substring(j, k));
        if (!Number.isNaN(v)) return v;
      }
    }
  }
  // "timestamp":"2024-10-18T12:34:56Z"
  p = seg.indexOf('"timestamp"');
  if (p >= 0) {
    const colon = seg.indexOf(':', p);
    if (colon >= 0) {
      const q1 = seg.indexOf('"', colon + 1);
      if (q1 >= 0) {
        const q2 = seg.indexOf('"', q1 + 1);
        if (q2 > q1 + 1) {
          const iso = seg.substring(q1 + 1, q2);
          const ms = Date.parse(iso);
          if (!Number.isNaN(ms)) return ms;
        }
      }
    }
  }
  return Date.now();
}
// 读取整个文件为 UTF-8 文本；stat 失败也能工作
async function readAllUtf8(uri: string): Promise<string> {
  let fh: fs.File | null = null;
  try {
    fh = await fs.open(uri, fs.OpenMode.READ_ONLY);

    const parts: string[] = [];
    const chunk = 64 * 1024; // 64KB
    while (true) {
      const buf = new ArrayBuffer(chunk);
      const n = await fs.read(fh.fd, buf);  // 返回本次读到的字节数
      if (n <= 0) break;
      parts.push(decodeUtf8(new Uint8Array(buf, 0, n)));
      if (n < chunk) break; // 读到不足一块 -> EOF
    }
    return parts.join('');
  } finally {
    if (fh) { try { await fs.close(fh.fd); } catch {} }
  }
}

// 固定、简单的类型：记录里只有 t 和 payload，完全避开索引签名/交叉类型
export interface HistoryRecord {
  t: number;
  payload: object;   // 原始对象整体塞这里（ArkTS 允许 object）
}

// 追加历史
export async function appendHistory(ctx: common.Context, item: object): Promise<void> {
  await ensureFile(ctx);
  const fh = await fs.open(historyPath(ctx), fs.OpenMode.APPEND);

  const rec: HistoryRecord = { t: Date.now(), payload: item };
  const line = JSON.stringify(rec) + '\n';

  const u8 = encodeUtf8(line);
  await writeBytes(fh.fd, u8);
  await fs.close(fh);
}

// 读取历史（倒序，最多 limit 条）
export async function listHistoryFromAppFilesDir(ctx: common.Context, limit: number = 200): Promise<HistoryRecord[]> {
  await ensureFile(ctx);
  const p = historyPath(ctx);
  const stat = await fs.stat(p);
  const fh = await fs.open(p, fs.OpenMode.READ_ONLY);
  const buf = new ArrayBuffer(stat.size);
  await fs.read(fh.fd, buf);
  await fs.close(fh);

  const text = decodeUtf8(new Uint8Array(buf));
  const trimmed = text.trim();
  if (trimmed.length === 0) return [];

  const lines = trimmed.split('\n');
  const out: HistoryRecord[] = [];
  for (let i = lines.length - 1; i >= 0 && out.length < limit; i--) {
    try {
      const obj = JSON.parse(lines[i]) as HistoryRecord;
      // 基本健壮性校验
      if (typeof obj === 'object' && obj !== null && typeof obj.t === 'number') {
        out.push(obj);
      }
    } catch { /* 跳过坏行 */ }
  }
  return out;  // 新 -> 旧
}

// 可选：清空
export async function clearHistoryInAppFilesDir(ctx: common.Context): Promise<void> {
  try { await fs.unlink(historyPath(ctx)); } catch {}
  await ensureFile(ctx);
}

function getBytesArg(call: MethodCall, key: string): Uint8Array {
  const mc = call as HasArgument;
  const v = (typeof mc.argument === 'function') ? mc.argument(key) : undefined;

  // 来自 Dart 的 Uint8List → Uint8Array
  if (v instanceof Uint8Array) return v;

  // 一些机型会变成 ArrayBuffer
  if (v instanceof ArrayBuffer) return new Uint8Array(v as ArrayBuffer);

  // 少数桥接会给 number[]（逐字节）
  if (Array.isArray(v)) {
    const arr = v as number[];
    return new Uint8Array(arr);
  }

  // 万不得已：字符串也能写（例如调试）
  if (typeof v === 'string') return utf8Encode(v);

  throw new Error('Invalid argument');
}
type Throwable =
  | Error
  | BusinessError
  | string
  | number
  | boolean
  | object
  | null
  | undefined;

interface HasMessage { message?: string }
interface HasCode { code: number }

function normalizeError(e: Throwable): Error {
  if (e instanceof Error) return e;

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
  } catch { }

  return new Error(String(e));
}

let fileOpsCh: MethodChannel | undefined;

function emitLog(msg: string) {
  try {
    fileOpsCh?.invokeMethod('onLog', { t: Date.now(), msg });
  } catch (_) {
  }
}

interface HasArgument {
  argument?: (key: string) => string | number | boolean | object | null | undefined;
}
type ArgFn = (key: string) =>
string | number | boolean | object | null | undefined;

function getStrArg(call: MethodCall, key: string, defVal: string): string {
  const mc = call as HasArgument;
  const v = (typeof mc.argument === 'function') ? mc.argument(key) : undefined;
  return (typeof v === 'string') ? v : defVal;
}

function v(ch: number): number {
  // 'A'-'Z'
  if (ch >= 65 && ch <= 90) return ch - 65;
  // 'a'-'z'
  if (ch >= 97 && ch <= 122) return ch - 71; // 97-26
  // '0'-'9'
  if (ch >= 48 && ch <= 57) return ch + 4;   // 52..61
  // '+'
  if (ch === 43) return 62;
  // '/'
  if (ch === 47) return 63;
  // '=' or others
  return 0;
}
function b64ToBytes(b64: string): Uint8Array {
  // 只保留合法字符
  const s = b64.replace(/[^A-Za-z0-9+/=]/g, '');
  const len = s.length;
  let pad = 0;
  if (len >= 2) {
    if (s.charAt(len - 1) === '=') pad++;
    if (s.charAt(len - 2) === '=') pad++;
  }
  const outLen = (len >> 2) * 3 - pad;
  const out = new Uint8Array(outLen);

  let o = 0;
  let i = 0;
  while (i < len) {
    const c1 = v(s.charCodeAt(i++));
    const c2 = v(s.charCodeAt(i++));
    const c3 = v(s.charCodeAt(i++));
    const c4 = v(s.charCodeAt(i++));
    const trip = (c1 << 18) | (c2 << 12) | (c3 << 6) | c4;

    if (o < outLen) out[o++] = (trip >> 16) & 0xFF;
    if (o < outLen) out[o++] = (trip >> 8) & 0xFF;
    if (o < outLen) out[o++] = trip & 0xFF;
  }
  return out;
}

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

interface WifiScanInfo {
  ssid?: string;
  bssid?: string;
  bssidType?: number;
  capabilities?: string;
  securityType?: number;
  rssi?: number;
  band?: number;
  frequency?: number;
  channelWidth?: number;
  centerFrequency0?: number;
  centerFrequency1?: number;
  timestamp?: number;
  supportedWifiCategory?: number;
}

interface WifiStdOut {
  ssid: string;
  bssid: string;
  level: number;
  frequency: number;
  capabilities: string;
  wifiStandardCode: number | null;
  wifiStandardRaw: string | null;
  channelWidthCode: number | null;
  channelWidthRaw: string | null;
  centerFreq0: number | null;
  centerFreq1: number | null;
}

function mapWifiCategoryToStdCode(cat: number | null): number | null {
  if (cat === 4 || cat === 5) return 7;
  if (cat === 2 || cat === 3) return 6;
  return null;
}

function packOut(it: WifiScanInfo): WifiStdOut {
  const ssid = it.ssid ?? '';
  const bssid = (it.bssid ?? '').toLowerCase();
  const level = (it.rssi ?? -100) as number;
  const frequency = (it.frequency ?? 0) as number;
  const capabilities = it.capabilities ?? '';

  const cat: number | null = (it.supportedWifiCategory ?? null) as number | null;
  const wifiStandardCode = mapWifiCategoryToStdCode(cat);
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

let lastScanAt = 0;

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

export async function getScanStandards(): Promise<WifiStdOut[]> {
  return getScanListUnique();
}

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
    await writeBytes(fh.fd, data);
    emitLog('ArkTS: fs.write ok');

    return target;
  } catch (e) {
    const err = normalizeError(e);
    emitLog(`ArkTS: fs error ${err.message}`);
    throw err;
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
  let mime = 'application/json';
  const low = target.toLowerCase();
  if (low.endsWith('.jsonl')) mime = 'text/plain';
  const want: Want = { action: 'ohos.want.action.viewData', uri: target, type: mime };
  await ctx.startAbility(want);
}

export default class EntryAbility extends FlutterAbility {
  private wifiCh?: MethodChannel;
  private fileCh?: MethodChannel;
  private uiCtx?: UIContext;

  private engineRef?: FlutterEngine;
  override configureFlutterEngine(engine: FlutterEngine): void {
    super.configureFlutterEngine(engine);
    this.engineRef = engine;
    this.ensureChannels(engine);
    emitLog('[EntryAbility] ensureChannels in configureFlutterEngine');
  }
  override onWindowStageCreate(windowStage: window.WindowStage): void {
    super.onWindowStageCreate(windowStage);
    windowStage.getMainWindow().then((win) => {
      this.uiCtx = win.getUIContext();
    });
    if (this.engineRef) this.ensureChannels(this.engineRef);
  }

  override onForeground(): void {
    super.onForeground();
    if (this.engineRef) {
      this.ensureChannels(this.engineRef);
      emitLog('[EntryAbility] ensureChannels in onForeground');
    }
  }

  override onDestroy(): void {
    this.fileCh = undefined;
    this.wifiCh = undefined;
    this.engineRef = undefined;
    super.onDestroy();
  }

  private ensureChannels(engine: FlutterEngine): void {
    if (!this.fileCh) {
      this.fileCh = new MethodChannel(engine.dartExecutor, 'file_ops');
      fileOpsCh = this.fileCh;
      this.fileCh.setMethodCallHandler({
        onMethodCall: (call: MethodCall, result: MethodResult) => {
          this.onFileOps(call, result);
        }
      });
    }
    if (!this.wifiCh) {
      this.wifiCh = new MethodChannel(engine.dartExecutor, 'wifi_std');
      this.wifiCh.setMethodCallHandler({
        onMethodCall: (call: MethodCall, result: MethodResult) => {
          this.onWifiStd(call, result);
        }
      });
    }
  }
  private async onFileOps(call: MethodCall, result: MethodResult): Promise<void> {
    emitLog(`ArkTS onFileOps: ${call.method}`);
    try {
      if (call.method === 'echo') {
        const v = getStrArg(call, 'v', '');
        emitLog(`file_ops echo <- "${v}"`);
        result.success({ ok: true, got: v });
        return;
      }
      // ① 选择保存位置并打开句柄，返回 sid
      // ① 追加：用已知 uri 打开文件并定位到末尾，返回 sid
      // ① 追加：用已知 uri 打开文件并定位到末尾，返回 sid
      if (call.method === 'appendStart') {
        const uri = getStrArg(call, 'uri', '');
        if (!uri) { result.success({ ok: false, message: 'empty uri' }); return; }

        emitLog(`[file_ops] appendStart uri=${uri}`);
        let fh: fs.File;
        try {
          fh = await fs.open(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
        } catch {
          fh = await fs.open(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
        }

        let before = -1;
        try { const st = await fs.stat(uri); before = st.size; } catch {}
        if (before > 0) { try { await writeBytes(fh.fd, new Uint8Array([10]));} catch {} }

        const sid = nextSid++;
        saveSessions.set(sid, { fd: fh.fd, uri, bytes: 0, chunks: 0, t0: Date.now() });
        emitLog(`[file_ops] appendStart ok sid=${sid} sizeBefore=${before >= 0 ? fmtBytes(before) : 'NA'}`);
        result.success({ ok: true, sid, uri });
        return;
      }


      // ② 追加：写入一块
      if (call.method === 'appendChunk') {
        const sid = Number(getStrArg(call, 'sid', '0'));
        const sess = saveSessions.get(sid);
        if (!sess) { result.success({ ok: false, message: 'bad sid' }); return; }

        // 优先 b64
        const b64 = getStrArg(call, 'b64', '');
        let payload: Uint8Array | null = null;
        let origin = 'b64';
        if (b64.length > 0) {
          payload = b64ToBytes(b64);
        } else {
          // 兼容老的 bytes（如果仍在调用 saveChunk/appendChunk 传 bytes）
          const mc = call as HasArgument;
          const v = (typeof mc.argument === 'function') ? mc.argument('bytes') : undefined;
          if (v instanceof Uint8Array) payload = v;
          else if (v instanceof ArrayBuffer) payload = new Uint8Array(v);
          else if (Array.isArray(v)) payload = new Uint8Array(v as number[]);
          origin = 'bytes';
        }

        if (!payload) { result.success({ ok: false, message: 'no payload' }); return; }

        await writeBytes(sess.fd, payload);
        sess.bytes += payload.byteLength;
        sess.chunks += 1;
        emitLog(`[file_ops] appendChunk sid=${sid} origin=${origin} wrote=${fmtBytes(payload.byteLength)} acc=${fmtBytes(sess.bytes)} #${sess.chunks}`);
        result.success({ ok: true, wrote: payload.byteLength });
        return;
      }
      if (call.method === 'statUri') {
        const uri = getStrArg(call, 'uri', '');
        if (!uri) { result.success({ ok: false, message: 'empty uri' }); return; }
        try {
          const st = await fs.stat(uri);
          result.success({ ok: true, exists: true, size: st.size });
        } catch (_) {
          try {
            const fh = await fs.open(uri, fs.OpenMode.READ_ONLY);
            await fs.close(fh);
            result.success({ ok: true, exists: true, size: -1 }); // 存在但未知大小
          } catch {
            result.success({ ok: true, exists: false, size: 0 });
          }
        }
        return;
      }


      if (call.method === 'appendFinish') {
        const sid = Number(getStrArg(call, 'sid', '0'));
        const sess = saveSessions.get(sid);
        if (!sess) { result.success({ ok: false, message: 'bad sid' }); return; }

        let after = -1;
        try { const st = await fs.stat(sess.uri); after = st.size; } catch {}

        try { await fs.close(sess.fd); } catch {}
        const dur = Date.now() - sess.t0;
        emitLog(`[file_ops] appendFinish sid=${sid} total=${fmtBytes(sess.bytes)} chunks=${sess.chunks} in ${dur}ms sizeAfter=${after >= 0 ? fmtBytes(after) : 'NA'}`);
        saveSessions.delete(sid);

        await this.fileCh?.invokeMethod('onSaved', { ok: true, uri: sess.uri });
        result.success({ ok: true, uri: sess.uri });
        return;
      }

      if (call.method === 'chooseSaveUri') {
        let base = getStrArg(call, 'baseName', 'wifi_scans');
        if (!base.endsWith('.jsonl') && !base.endsWith('.json')) base = `${base}.jsonl`; // 统一默认 jsonl

        const ctx = this.context as common.UIAbilityContext;
        const view = new picker.DocumentViewPicker(ctx);
        const opts = new picker.DocumentSaveOptions();
        opts.newFileNames = [base];          // 某些机型不会自动加句点，直接给完整名最稳
        // 不设置 fileSuffixChoices，避免出现 "wifi_scansjson"

        try {
          const uris: string[] = await view.save(opts);
          emitLog(`[file_ops] chooseSaveUri opts.base=${base} -> ${JSON.stringify(uris)}`);
          if (!uris || uris.length === 0) { result.success({ ok: false, canceled: true }); return; }
          result.success({ ok: true, uri: uris[0] });
        } catch (e) {
          const err = normalizeError(e);
          emitLog(`[file_ops] chooseSaveUri ERROR: ${err.message}`);
          result.error('500', err.message, null);
        }
        return;
      }


      // ② 逐块写
      if (call.method === 'saveChunk') {
        const sid = Number(getStrArg(call, 'sid', '0'));
        const sess = saveSessions.get(sid);
        if (!sess) { result.success({ ok: false, message: 'bad sid' }); return; }

        const b64 = getStrArg(call, 'b64', '');
        if (b64.length === 0) { result.success({ ok: false, message: 'empty b64' }); return; }

        const bytes = b64ToBytes(b64);
        await writeBytes(sess.fd, bytes);
        emitLog(`ArkTS onFileOps: saveChunk wrote=${bytes.byteLength}`);
        result.success({ ok: true, wrote: bytes.byteLength });
        return;
      }


      if (call.method === 'history.listFromUri') {
        try {
          const uri = getStrArg(call, 'uri', '');
          const limitStr = getStrArg(call, 'limit', '200');
          const limit = Number(limitStr) > 0 ? Number(limitStr) : 200;
          emitLog(`[history] listFromUri uri=${uri} limit=${limit}`);

          if (!uri) { result.success({ ok: false, message: 'empty uri', data: [] }); return; }

          // 1) 先尝试 stat，但即使失败也不中断
          let size = -1;
          try {
            const st = await fs.stat(uri);
            size = st.size;
            emitLog(`[history] stat ok size=${size}`);
          } catch (e) {
            emitLog(`[history] stat FAIL: ${normalizeError(e).message} (will try open+read)`);
          }

          // 2) 读取全文：若 size>=0 且不大可一次性读；否则走流式
          let text = '';
          if (size >= 0 && size <= 8 * 1024 * 1024) {       // 8MB 以内一次性读
            const fh = await fs.open(uri, fs.OpenMode.READ_ONLY);
            const buf = new ArrayBuffer(size);
            const n = await fs.read(fh.fd, buf);
            await fs.close(fh);
            emitLog(`[history] read bytes=${n}`);
            text = decodeUtf8(new Uint8Array(buf, 0, n));
          } else {
            text = await readAllUtf8(uri);
            emitLog(`[history] read(stream) textLen=${text.length}`);
          }

          const trimmed = text.trim();
          emitLog(`[history] trimmedLen=${trimmed.length} head="${preview(trimmed, 200)}"`);

          const segs = splitTopLevelObjects(trimmed);
          emitLog(`[history] segs.count=${segs.length}`);
          for (let i = 0; i < segs.length && i < 3; i++) {
            const t0 = tryParseEpochMsFromSegment(segs[i]);
            emitLog(`[history] seg#${i} len=${segs[i].length} t=${t0} head="${preview(segs[i], 120)}"`);
          }

          const rows: HistoryRowText[] = [];
          for (let i = 0; i < segs.length; i++) {
            const seg = segs[i];
            const t0 = tryParseEpochMsFromSegment(seg);
            rows.push({ t: t0, payload: seg });
          }

          const out = rows.length > limit ? rows.slice(rows.length - limit) : rows;
          out.reverse(); // 新 -> 旧
          emitLog(`[history] rows.out=${out.length}`);
          result.success({ ok: true, data: out, uri });
        } catch (e) {
          const err = normalizeError(e);
          emitLog(`[history] listFromUri ERROR: ${err.message}`);
          result.success({ ok: false, message: err.message, data: [] });
        }
        return;
      }

      // 从外部 JSON/JSONL 文件中按 t（毫秒时间戳）删除一条
      if (call.method === 'history.deleteFromUri') {
        emitLog('ArkTS onFileOps: history.deleteFromUri');
        const uri = getStrArg(call, 'uri', '');
        const segArg = getStrArg(call, 'segment', '');   // 可为空
        const tStr = getStrArg(call, 't', '0');          // 可为空
        const targetT = Number(tStr);

        if (!uri) { result.success({ ok: false, message: 'empty uri' }); return; }

        try {
          const text = (await readAllUtf8(uri)).trim();
          if (text.length === 0) {
            result.success({ ok: false, message: 'empty file' });
            return;
          }
          const segs = splitTopLevelObjects(text);
          emitLog(`[delete] total segs=${segs.length}`);

          // 找目标下标
          let idx = -1;

          // 1) 优先用精确段匹配（传入时最好把原始 payload 文本传回）
          if (segArg.length > 0) {
            const target = segArg.trim();
            for (let i = 0; i < segs.length; i++) {
              if (segs[i].trim() === target) { idx = i; break; }
            }
          }

          // 2) 兜底：按 t 匹配（可能不唯一，取最靠后的一个）
          if (idx < 0 && targetT > 0) {
            for (let i = segs.length - 1; i >= 0; i--) {
              if (tryParseEpochMsFromSegment(segs[i]) === targetT) { idx = i; break; }
            }
          }

          if (idx < 0) {
            emitLog('[delete] target not found');
            result.success({ ok: false, message: 'not found' });
            return;
          }

          // 重新拼接（保留换行）
          const kept: string[] = [];
          for (let i = 0; i < segs.length; i++) {
            if (i !== idx) kept.push(segs[i]);
          }
          const newText = kept.join('\n') + (kept.length > 0 ? '\n' : '');
          emitLog(`[delete] removed idx=${idx} newLen=${newText.length}`);

          // 覆盖写回（TRUNC）
          const fh = await fs.open(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          const u8 = encodeUtf8(newText);
          await writeBytes(fh.fd, u8);
          await fs.close(fh);

          result.success({ ok: true, removedIndex: idx, totalAfter: kept.length });
          return;
        } catch (e) {
          const err = normalizeError(e);
          emitLog(`[delete] ERROR: ${err.message}`);
          result.success({ ok: false, message: err.message });
          return;
        }
      }
      if (call.method === 'history.peek') {
        try {
          const uri = getStrArg(call, 'uri', '');
          const maxStr = getStrArg(call, 'max', '800');
          const max = Number(maxStr) > 0 ? Number(maxStr) : 800;
          if (!uri) { result.success({ ok: false, message: 'empty uri' }); return; }

          const st = await fs.stat(uri);
          const fh = await fs.open(uri, fs.OpenMode.READ_ONLY);
          const buf = new ArrayBuffer(st.size);
          await fs.read(fh.fd, buf);
          await fs.close(fh);

          const text = decodeUtf8(new Uint8Array(buf));
          const trimmed = text.trim();
          const segs = splitTopLevelObjects(trimmed);

          result.success({
            ok: true,
            size: st.size,
            textLen: text.length,
            trimmedLen: trimmed.length,
            segs: segs.length,
            head: preview(trimmed, max),
            tail: preview(trimmed.length > max ? trimmed.slice(trimmed.length - max) : trimmed, max)
          });
        } catch (e) {
          const err = normalizeError(e);
          result.success({ ok: false, message: err.message });
        }
        return;
      }
      // 逐步探测：stat → open → read(256B)，并打印每一步日志
      if (call.method === 'debug.fsProbe') {
        const uri = getStrArg(call, 'uri', '');
        emitLog(`[probe] uri=${uri}`);

        let exists = false;
        let size = -1;
        try {
          const st = await fs.stat(uri);
          exists = true;
          size = st.size;
          emitLog(`[probe] stat ok size=${size}`);
        } catch (e) {
          const err = normalizeError(e);
          emitLog(`[probe] stat FAIL: ${err.message}`);
        }

        let canOpen = false;
        let readBytes = 0;
        let head = '';
        try {
          const fh = await fs.open(uri, fs.OpenMode.READ_ONLY);
          canOpen = true;
          const buf = new ArrayBuffer(256);
          readBytes = await fs.read(fh.fd, buf);
          await fs.close(fh);
          head = decodeUtf8(new Uint8Array(buf).slice(0, readBytes));
          emitLog(`[probe] open+read ok n=${readBytes} head="${head.replace(/\n/g,'\\n')}"`);
        } catch (e) {
          const err = normalizeError(e);
          emitLog(`[probe] open/read FAIL: ${err.message}`);
        }

        result.success({
          ok: true,
          exists: exists,
          size: size,
          canOpen: canOpen,
          readBytes: readBytes,
          head: head.length > 120 ? head.slice(0, 120) : head
        });
        return;
      }

      // 选择一个已有的 JSON/JSONL 文件
      if (call.method === 'chooseOpenUri') {
        const ctx = this.context as common.UIAbilityContext;
        const view = new picker.DocumentViewPicker(ctx);
        const opts = new picker.DocumentSelectOptions();
        opts.maxSelectNumber = 1;
        try {
          const uris: string[] = await view.select(opts);   // 注意：是 select()（保存是 save()）
          emitLog(`[file_ops] chooseOpenUri -> ${JSON.stringify(uris)}`);
          if (!uris || uris.length === 0) { result.success({ ok: false, canceled: true }); return; }
          result.success({ ok: true, uri: uris[0] });
        } catch (e) {
          const err = normalizeError(e);
          emitLog(`[file_ops] chooseOpenUri ERROR: ${err.message}`);
          result.error('500', err.message, null);
        }
        return;
      }

      // ③ 完成并关闭
      if (call.method === 'saveFinish') {
        const sidStr = getStrArg(call, 'sid', '0');
        const sid = Number(sidStr);
        const sess = saveSessions.get(sid);
        if (!sess) { result.success({ ok: false, message: 'bad sid' }); return; }

        try { await fs.close(sess.fd); } catch {}
        saveSessions.delete(sid);

        // 复用你已有的回推
        await this.fileCh?.invokeMethod('onSaved', { ok: true, uri: sess.uri });
        emitLog('ArkTS: onSaved(ok) sent');
        result.success({ ok: true, uri: sess.uri });
        return;
      }

      if (call.method === 'ping') {
        result.success(true);
        return;
      }

      if (call.method === 'saveToDownloads') {
        const fileName = getStrArg(call, 'fileName', 'wifi_scans.json');
        const text = getStrArg(call, 'text', '');
        result.success({ ok: true, pending: true });

        (async () => {
          try {
            const ctx = this.context as common.UIAbilityContext;
            emitLog('ArkTS: open picker');
            const uri = await saveJsonToDownloads(
              ctx,
              fileName,
              text
            );

            emitLog(`ArkTS: got uri = ${uri}`);
            await this.fileCh?.invokeMethod('onSaved', { ok: true, uri });
          } catch (e) {
            const err = normalizeError(e);
            emitLog(`ArkTS: save fail ${err.message}`);
            await this.fileCh?.invokeMethod('onSaved', { ok: false, message: err.message });
          }
        })();
        return;
      }
      // ---- History APIs ----
      if (call.method === 'history.append') {
        const mc = call as HasArgument;
        const item = (typeof mc.argument === 'function') ? mc.argument('item') : undefined;
        if (!item || typeof item !== 'object') {
          result.success({ ok: false, message: 'bad item' });
          return;
        }
        try {
          await appendHistory(this.context as common.Context, item as object);
          result.success({ ok: true });
        } catch (e) {
          const err = normalizeError(e);
          result.success({ ok: false, message: err.message });
        }
        return;
      }

      if (call.method === 'history.list') {
        const mc = call as HasArgument;
        const limAny = (typeof mc.argument === 'function') ? mc.argument('limit') : undefined;
        const limit = typeof limAny === 'number' ? limAny : 200;
        try {
          const data = await listHistoryFromAppFilesDir(this.context as common.Context, limit);
          result.success({ ok: true, data });   // Dart 侧按前面 HistoryApi.list 去解析
        } catch (e) {
          const err = normalizeError(e);
          result.success({ ok: false, message: err.message, data: [] });
        }
        return;
      }

      if (call.method === 'history.clear') {
        try {
          await clearHistoryInAppFilesDir(this.context as common.Context);
          result.success({ ok: true });
        } catch (e) {
          const err = normalizeError(e);
          result.success({ ok: false, message: err.message });
        }
        return;
      }
      // ---- end History APIs ----


      if (call.method === 'saveProbe') {
        const fileName = getStrArg(call, 'fileName', 'probe.json');
        const ctx = this.context as common.UIAbilityContext;
        const view = new picker.DocumentViewPicker(ctx);
        const opts = new picker.DocumentSaveOptions();
        opts.newFileNames = [fileName];
        opts.fileSuffixChoices = ['json'];
        try {
          const uris: string[] = await view.save(opts);
          emitLog(`ArkTS: probe uris=${JSON.stringify(uris)}`);
          result.success({ ok: true, uris });
        } catch (e) {
          const err = normalizeError(e);
          emitLog(`ArkTS: probe fail ${err.message}`);
          result.error('500', err.message, null);
        }
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
  private async onWifiStd(call: MethodCall, result: MethodResult): Promise<void> {
    emitLog(`ArkTS onWifiStd: ${call.method}`);
    try {
      if (call.method === 'echo') {
        const v = getStrArg(call, 'v', '');
        emitLog(`wifi_std echo <- "${v}"`);
        result.success({ ok: true, got: v });
        return;
      }
      if (call.method === 'ping') {
        result.success(true);
        return;
      }

      if (call.method === 'scanAndGet') {
        try {
          const data = await scanAndGet();
          result.success(data);
        } catch (e) {
          const err = normalizeError(e);
          result.error('500', err.message, null);
        }
        return;
      }

      if (call.method === 'getScanStandards') {
        try {
          const data = await getScanStandards();
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
}