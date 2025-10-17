import { FlutterAbility, FlutterEngine, MethodCall, MethodResult, MethodChannel } from '@ohos/flutter_ohos';
import wifiManager from '@ohos.wifiManager';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import type Want from '@ohos.app.ability.Want';
import { BusinessError } from '@ohos.base';
import window from '@ohos.window';
import type { UIContext } from '@ohos.arkui.UIContext';

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
        } catch {
          result.success({ ok: true, exists: false, size: 0 });
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