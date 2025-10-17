import { FlutterAbility, FlutterEngine, MethodCall, MethodResult, MethodChannel } from '@ohos/flutter_ohos';
import wifiManager from '@ohos.wifiManager';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import type Want from '@ohos.app.ability.Want';
import { BusinessError } from '@ohos.base';
import window from '@ohos.window';
import type { UIContext } from '@ohos.arkui.UIContext';

// ===== 放在顶部（emitLog 附近）=====

interface SaveSession { fd: number; uri: string }
const saveSessions = new Map<number, SaveSession>();
let nextSid = 1;

// 从平台通道参数里拿出字节（不使用 any/unknown）
function getBytesArg(call: MethodCall, key: string): Uint8Array {
  const mc = call as HasArgument;               // 你已有：interface HasArgument { argument?: ArgFn }
  const v = mc.argument ? (mc.argument(key)) : undefined;

  if (v instanceof Uint8Array) return v;
  if (v instanceof ArrayBuffer) return new Uint8Array(v as ArrayBuffer);
  if (Array.isArray(v)) return new Uint8Array(v as number[]); // 兼容 number[]
  throw new Error('bad bytes');
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

interface HasArgument { argument?: ArgFn }
type ArgFn = (key: string) =>
string | number | boolean | object | null | undefined;

function getStrArg(call: MethodCall, key: string, defVal: string): string {
  const mc = call as HasArgument;
  const v = (typeof mc.argument === 'function') ? mc.argument(key) : undefined;
  return (typeof v === 'string') ? v : defVal;
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
    await fs.write(fh.fd, data);
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
  const want: Want = {
    action: 'ohos.want.action.viewData',
    uri: target,
    type: 'application/json',
  };
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
      if (call.method === 'saveStart') {
        const fileName = getStrArg(call, 'fileName', 'wifi_scans.json');
        const abilityCtx = this.context as common.UIAbilityContext;

        const view = new picker.DocumentViewPicker(abilityCtx);
        const opts = new picker.DocumentSaveOptions();
        opts.newFileNames = [fileName];
        opts.fileSuffixChoices = ['json'];

        const uris: string[] = await view.save(opts);
        if (!uris || uris.length === 0) { result.success({ ok: false, canceled: true }); return; }

        const uri = uris[0];
        const fh = await fs.open(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE); // 不带 TRUNC，更通用
        const sid = nextSid++;

        saveSessions.set(sid, { fd: fh.fd, uri });
        emitLog(`ArkTS: saveStart ok sid=${sid} uri=${uri}`);
        result.success({ ok: true, sid, uri });
        return;
      }
      // ① 追加：用已知 uri 打开文件并定位到末尾，返回 sid
      // ① 追加：用已知 uri 打开文件并定位到末尾，返回 sid
      if (call.method === 'appendStart') {
        const uri = getStrArg(call, 'uri', '');
        if (!uri) { result.success({ ok: false, message: 'empty uri' }); return; }

        // 只用强类型：READ_WRITE | CREATE | APPEND
        const fh = await fs.open(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);

        // 如果已有内容，先补一个换行，保证 JSONL 每条独占一行
        try {
          const st = await fs.stat(uri);
          if (st.size > 0) { await fs.write(fh.fd, new Uint8Array([10])); }
        } catch { /* stat 失败可忽略 */ }

        const sid = nextSid++;
        saveSessions.set(sid, { fd: fh.fd, uri });
        emitLog(`ArkTS: appendStart ok sid=${sid}`);
        result.success({ ok: true, sid, uri });
        return;
      }

      // ② 追加：写入一块
      if (call.method === 'appendChunk') {
        const sid = Number(getStrArg(call, 'sid', '0'));
        const sess = saveSessions.get(sid);
        if (!sess) { result.success({ ok: false, message: 'bad sid' }); return; }
        const bytes = getBytesArg(call, 'bytes');
        await fs.write(sess.fd, bytes);
        result.success({ ok: true, wrote: bytes.byteLength });
        return;
      }

      // ③ 追加：完成并关闭（回推 onSaved）
      if (call.method === 'appendFinish') {
        const sid = Number(getStrArg(call, 'sid', '0'));
        const sess = saveSessions.get(sid);
        if (!sess) { result.success({ ok: false, message: 'bad sid' }); return; }
        try { await fs.close(sess.fd); } catch {}
        saveSessions.delete(sid);
        await this.fileCh?.invokeMethod('onSaved', { ok: true, uri: sess.uri }); // 复用你已有的回推
        emitLog('ArkTS: onSaved(ok) sent (append)');
        result.success({ ok: true, uri: sess.uri });
        return;
      }

      // ② 逐块写
      if (call.method === 'saveChunk') {
        const sidStr = getStrArg(call, 'sid', '0');
        const sid = Number(sidStr);
        const sess = saveSessions.get(sid);
        if (!sess) { result.success({ ok: false, message: 'bad sid' }); return; }

        const bytes = getBytesArg(call, 'bytes');
        await fs.write(sess.fd, bytes);
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