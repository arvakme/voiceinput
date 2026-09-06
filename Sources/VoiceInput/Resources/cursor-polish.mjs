// Official SDK adapter; install @cursor/sdk explicitly once, never on a run.
// https://prod.cursor.com/docs/sdk/typescript
import { createRequire } from 'node:module';
import { mkdir, readFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';

export function requestOptions(request, sdk, directory, store) {
  return {
    apiKey: request.apiKey,
    model: { id: request.model, ...(request.modelParams ? { params: request.modelParams } : {}) },
    tools: [],
    disallowedTools: ['shell', 'mcp', 'task'],
    mcpServers: {},
    agents: {},
    local: {
      cwd: directory,
      dirs: [],
      settingSources: [],
      customTools: {},
      store: store ?? new sdk.JsonlLocalAgentStore(join(directory, 'session-store')),
    },
  };
}

export function completedText(result, nonce) {
  if (result?.error && safeCode(result.error) !== 'request_failed') throw result.error;
  if (!result || result.status !== 'finished' || result.error || typeof result.result !== 'string') {
    throw new Error('incomplete');
  }
  // SDK RunResult has no public token-limit/finish-reason field. A complete,
  // nonce-bound envelope is required, so truncated text is never injected.
  let envelope;
  try { envelope = JSON.parse(result.result); } catch { throw new Error('incomplete'); }
  if (!envelope || Array.isArray(envelope) || typeof envelope !== 'object'
      || Object.keys(envelope).length !== 2 || envelope.completion !== nonce
      || typeof envelope.text !== 'string' || !envelope.text.trim()
      || Buffer.byteLength(envelope.text, 'utf8') > 262144) {
    throw new Error('incomplete');
  }
  return envelope.text.trim();
}

export async function runPolish(request, sdk, directory, signal, context = {}) {
  if (!request || typeof request.apiKey !== 'string' || !request.apiKey.trim()
      || typeof request.model !== 'string' || !request.model.trim()
      || typeof request.input !== 'string' || !request.input.trim()
      || typeof request.role !== 'string' || !request.role.trim()
      || typeof request.nonce !== 'string' || !request.nonce.trim()) {
    throw new Error('configuration');
  }
  if (request.modelParams !== undefined && (!Array.isArray(request.modelParams)
      || request.modelParams.length > 32 || request.modelParams.some(param => !param
        || typeof param.id !== 'string' || typeof param.value !== 'string'
        || param.id.length > 128 || param.value.length > 128))) throw new Error('configuration');
  let agent, run, cancellation, settled = false;
  const cancel = () => {
    if (run && !cancellation) {
      cancellation = Promise.resolve().then(() => run.cancel());
      // A rejection is consumed now and checked by the bounded cleanup below.
      void cancellation.catch(() => {});
    }
  };
  signal?.addEventListener('abort', cancel, { once: true });
  try {
    if (signal?.aborted) throw new Error('cancelled');
    const createStart = performance.now();
    const options = requestOptions(request, sdk, directory, context.store);
    agent = await (context.platform ? context.platform.createAgent(options) : sdk.Agent.create(options));
    if (context.timings) context.timings.agentCreateMs = performance.now() - createStart;
    if (signal?.aborted) throw new Error('cancelled');
    const prompt = `${request.role}\n\n${request.input}\n\n`
      + 'Output protocol: return exactly one JSON object with "text" holding the transformed transcript '
      + `and "completion" holding ${JSON.stringify(request.nonce)}. Put completion after text. `
      + 'Do not wrap the JSON in Markdown. This envelope is transport formatting, not part of the transcript.';
    const sendStart = performance.now();
    run = await agent.send(prompt, { onDelta: ({ update }) => {
      if (context.timings && context.timings.firstTokenMs === null
          && update?.type === 'text-delta' && update.text) {
        context.timings.firstTokenMs = performance.now() - sendStart;
      }
    } });
    if (context.timings) context.timings.sendMs = performance.now() - sendStart;
    if (signal?.aborted) { cancel(); throw new Error('cancelled'); }
    const result = await abortable(run.wait(), signal);
    settled = true;
    if (signal?.aborted) throw new Error('cancelled');
    return completedText(result, request.nonce);
  } finally {
    signal?.removeEventListener('abort', cancel);
    if (agent) {
      if (signal?.aborted || (run && !settled)) cancel();
      const cancelledCleanly = !cancellation || await settlesWithin(cancellation, 800);
      const disposed = await disposeAgent(agent);
      if (context.platform) {
        // New agent per dictation means no preceding transcript in the next
        // model context; only the expensive executor and HTTP stack are reused.
        const deleted = !agent.agentId || (cancelledCleanly && disposed
          && await settlesWithin(Promise.resolve().then(() => context.platform.deleteAgent(agent.agentId)), 800));
        context.store.clear();
        // Cleanup health must never overwrite a complete result or the original
        // failure. Retire this worker after delivering that terminal reply.
        if (!cancelledCleanly || !disposed || !deleted) context.unhealthy = true;
      }
    }
  }
}

async function main() {
  const output = process.stdout.write.bind(process.stdout);
  const diagnostic = process.stderr.write.bind(process.stderr);
  // Dependencies occasionally log startup banners. Stdout is exclusively
  // our final result; never relay SDK logs (they can contain input or keys).
  process.stdout.write = (_chunk, encoding, callback) => {
    if (typeof encoding === 'function') encoding();
    else if (typeof callback === 'function') callback();
    return true;
  };
  process.stderr.write = (_chunk, encoding, callback) => {
    if (typeof encoding === 'function') encoding();
    else if (typeof callback === 'function') callback();
    return true;
  };
  if (process.argv.includes('--worker')) return workerMain(output);
  const controller = new AbortController();
  const cancel = () => controller.abort();
  process.once('SIGTERM', cancel);
  process.once('SIGINT', cancel);
  const timeout = setTimeout(cancel, 55000);
  try {
    const [major, minor] = process.versions.node.split('.').map(Number);
    if (major < 22 || (major === 22 && minor < 13)) throw new Error('node_version');
    let input = '';
    process.stdin.setEncoding('utf8'); // Preserve CJK split across pipe chunks.
    for await (const chunk of process.stdin) {
      input += chunk;
      if (Buffer.byteLength(input, 'utf8') > 1048576) throw new Error('input_size');
    }
    let request;
    try { request = JSON.parse(input); } catch { throw new Error('configuration'); }
    if (typeof request.sdkDirectory !== 'string' || !isAbsolute(request.sdkDirectory)) {
      throw new Error('configuration');
    }
    const directory = process.cwd();
    await mkdir(join(directory, 'session-store'), { recursive: true, mode: 0o700 });
    // Use the SDK's documented production endpoints, not ambient development
    // backend overrides that could receive a user's API key.
    delete process.env.CURSOR_BACKEND_URL;
    delete process.env.CURSOR_WEBSITE_URL;
    let sdk;
    try {
      const manifest = JSON.parse(await readFile(
        join(request.sdkDirectory, 'node_modules', '@cursor', 'sdk', 'package.json'), 'utf8'));
      if (manifest.name !== '@cursor/sdk' || manifest.version !== '1.0.31') {
        throw new Error('sdk_version');
      }
      // Resolve only from the explicit installation directory, without npx,
      // network installs or relying on the GUI app's current project.
      const require = createRequire(join(request.sdkDirectory, 'package.json'));
      sdk = require('@cursor/sdk');
    } catch (error) {
      throw new Error(error?.message === 'sdk_version' ? 'sdk_version' : 'sdk_missing');
    }
    if (!sdk.Agent?.create || !sdk.JsonlLocalAgentStore) throw new Error('sdk_version');
    const text = await runPolish(request, sdk, directory, controller.signal);
    clearTimeout(timeout);
    output(text, () => process.exit(0));
  } catch (error) {
    clearTimeout(timeout);
    const code = ['node_version', 'input_size', 'configuration', 'sdk_missing', 'sdk_version', 'incomplete', 'cancelled']
      .includes(error?.message) ? error.message : 'request_failed';
    // Stable codes only: never print third-party error.message/stack.
    diagnostic(`Cursor SDK: ${code}\n`, () => process.exit(1));
  }
}



function abortable(promise, signal) {
  if (!signal) return promise;
  return new Promise((resolve, reject) => {
    const abort = () => reject(new Error('cancelled'));
    signal.addEventListener('abort', abort, { once: true });
    Promise.resolve(promise).then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
    if (signal.aborted) abort();
  });
}

async function settlesWithin(promise, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      Promise.resolve(promise).then(() => true, () => false),
      new Promise(resolve => { timer = setTimeout(() => resolve(false), milliseconds); }),
    ]);
  } finally { clearTimeout(timer); }
}

async function disposeAgent(agent) {
  const cleanup = typeof agent[Symbol.asyncDispose] === 'function'
    ? () => agent[Symbol.asyncDispose]() : () => agent.close?.();
  return settlesWithin(Promise.resolve().then(cleanup), 800);
}

const safeCodes = new Set(['node_version', 'input_size', 'configuration', 'sdk_missing',
  'sdk_version', 'incomplete', 'cancelled', 'request_failed', 'busy', 'worker_unhealthy']);
export function safeCode(error) {
  if (safeCodes.has(error?.message)) return error.message;
  const code = String(error?.code ?? '').toLowerCase();
  if (code === 'unauthenticated' || error?.status === 401) return 'authentication';
  if (code === 'permission_denied' || error?.status === 403) return 'permission';
  if (['resource_exhausted', 'rate_limit_exceeded', 'rate_limited'].includes(code) || error?.status === 429) return 'rate_limit';
  if (['invalid_argument', 'not_found', 'model_not_found', 'invalid_model', 'failed_precondition'].includes(code)
      || [400, 404].includes(error?.status)) return 'model_configuration';
  if (['deadline_exceeded', 'etimedout'].includes(code) || error?.status === 504) return 'timeout';
  if (code === 'cancelled' || error?.name === 'AbortError') return 'cancelled';
  if (['unavailable', 'internal', 'econnreset', 'econnrefused', 'enotfound', 'eai_again'].includes(code)
      || [500, 502, 503].includes(error?.status) || error?.name === 'NetworkError') return 'network';
  // Unknown third-party text is never echoed; it can contain credentials or input.
  return error?.isRetryable === true ? 'temporary' : 'request_failed';
}

export function retryable(error) {
  return error?.isRetryable !== false && ['network', 'timeout', 'temporary'].includes(safeCode(error));
}

export async function loadSDK(sdkDirectory) {
  if (typeof sdkDirectory !== 'string' || !isAbsolute(sdkDirectory)) throw new Error('configuration');
  delete process.env.CURSOR_BACKEND_URL;
  delete process.env.CURSOR_WEBSITE_URL;
  try {
    const manifest = JSON.parse(await readFile(join(sdkDirectory, 'node_modules', '@cursor', 'sdk', 'package.json'), 'utf8'));
    if (manifest.name !== '@cursor/sdk' || manifest.version !== '1.0.31') throw new Error('sdk_version');
    const require = createRequire(join(sdkDirectory, 'package.json'));
    const sdk = require('@cursor/sdk');
    if (!sdk.Agent?.create || !sdk.createAgentPlatform || !sdk.createInMemoryRunEventNotifier) {
      throw new Error('sdk_version');
    }
    return sdk;
  } catch (error) {
    throw new Error(error?.message === 'sdk_version' ? 'sdk_version' : 'sdk_missing');
  }
}

/// Public LocalAgentStore contract, kept in RAM only. No transcript JSONL,
/// checkpoints, SQLite databases or per-dictation directories on disk.
export function createMemoryStore() {
  const agents = new Map(), runs = new Map(), checkpoints = new Map(), events = new Map();
  const maps = [agents, runs, checkpoints, events];
  const eventIndices = new Map();
  let size = 0;
  const maxBytes = 64 * 1024 * 1024;
  const clone = value => value == null ? value : structuredClone(value);
  const bytes = value => value instanceof Uint8Array ? value.byteLength : Buffer.byteLength(JSON.stringify(value), 'utf8');
  const put = (map, key, value) => {
    const amount = bytes(value), previous = map.get(key);
    const nextSize = size - (previous?.bytes ?? 0) + amount;
    if (nextSize > maxBytes) throw new Error('input_size');
    map.set(key, { value: clone(value), bytes: amount });
    size = nextSize;
    return clone(value);
  };
  const get = (map, key) => clone(map.get(key)?.value ?? null);
  const values = map => [...map.values()].map(item => item.value);
  const remove = (map, predicate) => {
    for (const [key, item] of map) if (predicate(item.value, key)) {
      size -= item.bytes; map.delete(key);
    }
  };
  const matches = (value, filter = {}) =>
    (!filter.agentIds?.length || filter.agentIds.includes(value.agentId))
    && (!filter.runIds?.length || filter.runIds.includes(value.runId))
    && (!filter.cwd || filter.cwd === value.cwd);
  const page = (items, filter = {}) => {
    const start = Number(filter.cursor ?? 0), limit = filter.limit ?? 100;
    const end = Math.min(items.length, start + limit);
    return { items: clone(items.slice(start, end)), ...(end < items.length ? { nextCursor: String(end) } : {}) };
  };
  return {
    agents: {
      get: async ({ agentId }) => get(agents, agentId),
      create: async ({ agent }) => put(agents, agent.agentId, agent),
      update: async ({ agent }) => put(agents, agent.agentId, agent),
      delete: async ({ filter }) => remove(agents, value => matches(value, filter)),
      list: async ({ filter = {} } = {}) => page(values(agents).filter(value => matches(value, filter))
        .sort((a, b) => b.updatedAt - a.updatedAt || a.agentId.localeCompare(b.agentId)), filter),
    },
    runs: {
      get: async ({ agentId, runId }) => get(runs, `${agentId}:${runId}`),
      create: async ({ run }) => put(runs, `${run.agentId}:${run.runId}`, run),
      update: async ({ run }) => put(runs, `${run.agentId}:${run.runId}`, run),
      delete: async ({ filter }) => remove(runs, value => matches(value, filter)),
      list: async ({ filter = {} } = {}) => page(values(runs).filter(value => matches(value, filter))
        .sort((a, b) => a.turnNumber - b.turnNumber || a.runId.localeCompare(b.runId)), filter),
    },
    checkpoints: {
      get: async ({ agentId, blobId }) => get(checkpoints, `${agentId}:${blobId}`),
      create: async ({ agentId, blobId, data }) => { put(checkpoints, `${agentId}:${blobId}`, data); },
      update: async ({ agentId, blobId, data }) => { put(checkpoints, `${agentId}:${blobId}`, data); },
      delete: async ({ filter = {} }) => remove(checkpoints, (_, key) => {
        const [agentId, blobId] = key.split(':');
        return matches({ agentId }, filter) && (!filter.blobIds?.length || filter.blobIds.includes(blobId));
      }),
      list: async ({ filter = {} } = {}) => page([...checkpoints.keys()].filter(key => {
        const [agentId, blobId] = key.split(':');
        return matches({ agentId }, filter) && (!filter.blobIds?.length || filter.blobIds.includes(blobId));
      }).map(key => key.split(':')[1]).sort(), filter),
    },
    runEvents: {
      append: async ({ runId, eventType, payload = null, payloadRef = null, idempotencyKey = null }) => {
        let index = eventIndices.get(runId);
        if (!index) { index = { keys: [], idempotency: new Map() }; eventIndices.set(runId, index); }
        if (idempotencyKey && index.idempotency.has(idempotencyKey)) {
          return get(events, index.idempotency.get(idempotencyKey));
        }
        const seq = index.keys.length + 1;
        const event = { runId, seq, offset: String(seq), eventType, payload, payloadRef, idempotencyKey, createdAt: Date.now() };
        const key = `${runId}:${seq}`;
        const result = put(events, key, event);
        index.keys.push(key);
        if (idempotencyKey) index.idempotency.set(idempotencyKey, key);
        return result;
      },
      list: async ({ runId, afterOffset = null, limit = 100 }) => {
        const keys = eventIndices.get(runId)?.keys ?? [];
        const start = Number(afterOffset ?? 0);
        const items = keys.slice(start, start + limit).map(key => get(events, key));
        return { items, ...(items.length ? { nextOffset: items.at(-1).offset } : {}) };
      },
      delete: async ({ filter = {} }) => {
        for (const [runId, index] of eventIndices) {
          if (filter.runIds?.length && !filter.runIds.includes(runId)) continue;
          for (const key of index.keys) { size -= events.get(key)?.bytes ?? 0; events.delete(key); }
          eventIndices.delete(runId);
        }
      },
    },
    clear() { for (const map of maps) map.clear(); eventIndices.clear(); size = 0; },
    stats() { return { agents: agents.size, runs: runs.size, checkpoints: checkpoints.size, events: events.size, bytes: size }; },
  };
}

/// Serialized jobs share only runtime infrastructure. Every polish gets a
/// fresh agent and a clean store. Cancel can be processed while wait() awaits.
export class CursorPolishWorker {
  constructor({ directory, load = loadSDK, reply, onClosed = () => {} }) {
    this.directory = directory;
    this.load = load;
    this.reply = reply;
    this.onClosed = onClosed;
    this.queue = [];
    this.jobs = new Map();
    this.active = null;
    this.closing = false;
    this.sdkDirectory = null;
    this.sdk = null;
    this.platform = null;
    this.store = null;
    this.lease = null;
    this.leaseKey = null;
    this.shutdownPromise = null;
    this.primedSelection = null;
  }

  handle(message) {
    const id = message?.id;
    if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(id)) {
      this.reply({ id: 'protocol', ok: false, error: 'configuration' }); return;
    }
    if (message.op === 'cancel') {
      const job = this.jobs.get(id);
      if (job) {
        job.controller.abort();
        this.respond(job, { ok: false, error: 'cancelled' });
        if (job !== this.active) {
          this.queue = this.queue.filter(queued => queued !== job);
          this.jobs.delete(id);
        }
      }
      return;
    }
    if (message.op === 'shutdown') { void this.shutdown(id); return; }
    if (!['polish', 'warmup'].includes(message.op) || !message.request || this.closing) {
      this.reply({ id, ok: false, error: 'configuration' }); return;
    }
    if (this.jobs.has(id)) return; // Never emit a second terminal reply for an active id.
    if (this.jobs.size >= 8) { this.reply({ id, ok: false, error: 'busy' }); return; }
    const job = { id, op: message.op, request: message.request, received: performance.now(),
      controller: new AbortController(), responded: false };
    this.jobs.set(id, job);
    this.queue.push(job);
    void this.pump();
  }

  respond(job, result) {
    if (job.responded) return;
    job.responded = true;
    this.reply({ id: job.id, ...result });
  }

  async prepare(request, timings) {
    if (typeof request.sdkDirectory !== 'string' || !isAbsolute(request.sdkDirectory)) throw new Error('configuration');
    const start = performance.now();
    if (this.sdkDirectory !== request.sdkDirectory) {
      await this.release();
      const sdk = await this.load(request.sdkDirectory);
      const store = createMemoryStore();
      const platform = await sdk.createAgentPlatform({ localStore: store,
        workspaceRef: this.directory, scopedWorkspaceRef: this.directory,
        eventNotifier: sdk.createInMemoryRunEventNotifier() });
      this.sdk = sdk;
      this.store = store;
      this.platform = platform;
      this.sdkDirectory = request.sdkDirectory;
      this.primedSelection = null;
    }
    timings.sdkLoadMs = performance.now() - start;
    const key = typeof request.apiKey === 'string' ? request.apiKey : '';
    const warmStart = performance.now();
    if (!this.lease || key !== this.leaseKey) {
      // The executor cache key includes API key and workspace options, not model.
      // Hold one lease until app shutdown/key switch, so per-agent disposal does
      // not tear down the shared executor or its connection infrastructure.
      const next = await this.platform.prewarmLocalWorkspace(requestOptions({ ...request, apiKey: key }, this.sdk, this.directory, this.store));
      const old = this.lease;
      this.lease = next;
      this.leaseKey = key;
      if (old) await old();
    }
    timings.prewarmMs = performance.now() - warmStart;
  }

  async primeModel(request, timings) {
    if (typeof request.apiKey !== 'string' || !request.apiKey.trim()
        || typeof request.model !== 'string' || !request.model.trim()
        || typeof this.platform.resolveLocalModelSelection !== 'function') return;
    const selection = JSON.stringify([request.apiKey, request.model, request.modelParams ?? []]);
    if (selection === this.primedSelection) return;
    const started = performance.now();
    try {
      // Public CursorAgentPlatform API used by createAgent itself. Warm its
      // catalog cache directly: no QUEUED agent, analytics flush or disposal.
      // Metadata prefetch is optional; failures must not poison a healthy
      // executor or prevent the actual request from retrying the lookup.
      await this.platform.resolveLocalModelSelection(
        requestOptions(request, this.sdk, this.directory, this.store).model, request.apiKey);
      this.primedSelection = selection;
    } catch { /* Best-effort metadata optimization; actual create validates. */ }
    finally { timings.agentCreateMs = performance.now() - started; }
  }

  async pump() {
    if (this.active || this.closing) return;
    const job = this.queue.shift();
    if (!job) return;
    this.active = job;
    const started = performance.now();
    const timings = { sdkLoadMs: 0, prewarmMs: 0, agentCreateMs: 0, sendMs: 0,
      firstTokenMs: null, queueMs: started - job.received, totalMs: 0 };
    let timeout, timedOut = false;
    const context = { platform: null, store: null, timings, unhealthy: false };
    try {
      timeout = setTimeout(() => { timedOut = true; job.controller.abort(); }, 55000);
      await this.prepare(job.request, timings);
      if (job.controller.signal.aborted) throw new Error('cancelled');
      if (job.op === 'warmup') await this.primeModel(job.request, timings);
      let text;
      if (job.op === 'polish') {
        Object.assign(context, { platform: this.platform, store: this.store });
        for (let attempt = 0; attempt < 2; attempt++) {
          try {
            text = await runPolish(job.request, this.sdk, this.directory, job.controller.signal, context);
            break;
          } catch (error) {
            if (attempt || context.unhealthy || job.controller.signal.aborted || !retryable(error)) throw error;
            timings.retries = 1;
            await abortable(new Promise(resolve => setTimeout(resolve, 250)), job.controller.signal);
            // A fresh executor prevents reuse of a broken connection. The next
            // attempt still uses the same explicitly selected model/parameters.
            await this.release();
            await this.prepare(job.request, timings);
          }
        }
      }
      if (job.controller.signal.aborted) throw new Error('cancelled');
      timings.totalMs = performance.now() - job.received;
      this.respond(job, { ok: true, ...(text !== undefined ? { text } : {}), timings,
        ...(context.unhealthy ? { retire: true } : {}) });
    } catch (error) {
      timings.totalMs = performance.now() - job.received;
      this.respond(job, { ok: false, error: timedOut ? 'timeout' : safeCode(error), timings,
        ...(context.unhealthy ? { retire: true } : {}) });
      // A hung executor must not overlap a subsequent dictation. Swift will
      // restart the child; never keep sending on an uncertain cancellation.
      if (error?.message === 'worker_unhealthy') void this.shutdown();
    } finally {
      clearTimeout(timeout);
      if (context.unhealthy) void this.shutdown();
      this.active = null;
      this.jobs.delete(job.id);
      if (!this.closing) void this.pump();
    }
  }

  async release() {
    const lease = this.lease;
    this.lease = null;
    this.leaseKey = null;
    if (lease) await lease().catch(() => {});
    this.store?.clear();
  }

  shutdown(id) {
    if (this.shutdownPromise) return this.shutdownPromise;
    this.closing = true;
    for (const job of this.jobs.values()) {
      job.controller.abort();
      this.respond(job, { ok: false, error: 'cancelled' });
    }
    this.queue = [];
    this.shutdownPromise = (async () => {
      // Cancellation continues through the regular dispose/delete path. The
      // Swift host owns the hard two-second deadline for a stuck dependency.
      while (this.active) await new Promise(resolve => setTimeout(resolve, 10));
      this.jobs.clear();
      await this.release();
      if (id) this.reply({ id, ok: true });
      await this.onClosed();
    })();
    return this.shutdownPromise;
  }
}

async function workerMain(output) {
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 13)) {
    output(JSON.stringify({ id: 'protocol', ok: false, error: 'node_version' }) + '\n', () => process.exit(1));
    return;
  }
  let writes = Promise.resolve();
  const reply = value => {
    writes = writes.then(() => new Promise(resolve => output(JSON.stringify(value) + '\n', resolve)));
  };
  const worker = new CursorPolishWorker({ directory: process.cwd(), reply,
    onClosed: async () => { await writes; process.exit(0); } });
  const close = () => { void worker.shutdown(); };
  process.once('SIGTERM', close);
  process.once('SIGINT', close);
  process.stdin.setEncoding('utf8');
  let buffer = '';
  process.stdin.on('data', chunk => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (Buffer.byteLength(line, 'utf8') > 1048576) {
        reply({ id: 'protocol', ok: false, error: 'input_size' }); close(); return;
      }
      if (!line.trim()) continue;
      try { worker.handle(JSON.parse(line)); }
      catch { reply({ id: 'protocol', ok: false, error: 'configuration' }); }
    }
    if (Buffer.byteLength(buffer, 'utf8') > 1048576) {
      buffer = '';
      reply({ id: 'protocol', ok: false, error: 'input_size' }); close();
    }
  });
  process.stdin.on('end', close);
  process.stdin.on('error', close);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
