// Metadata only: never starts a generation, conversation, or coding task.
import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const model = (modelID, displayName = modelID, detail = '', parameters = []) => ({ modelID, displayName, detail, parameters });
const key = params => [...params].sort((a, b) => a.id.localeCompare(b.id)).map(p => `${p.id}=${p.value}`).join('&');

export function cursorChoices(models) {
  if (!Array.isArray(models)) throw Error('invalid_catalog');
  const result = [];
  for (const item of models) {
    if (typeof item.id !== 'string' || !item.id) continue;
    const definitions = (item.parameters ?? []).filter(p => typeof p.id === 'string' && Array.isArray(p.values) && p.values.length);
    const variants = (item.variants ?? []).filter(v => Array.isArray(v.params));
    const firstValues = definitions.map(p => ({ id: p.id, value: String(p.values[0].value) }));
    const defaults = new Map(firstValues.map(p => [p.id, p.value]));
    for (const p of variants.find(v => v.isDefault)?.params ?? []) defaults.set(p.id, String(p.value));
    const valid = params => params.every(p => definitions.some(d => d.id === p.id && d.values.some(v => String(v.value) === p.value)));
    const merge = params => [...new Map([...defaults, ...params.map(p => [p.id, String(p.value)])])].map(([id, value]) => ({ id, value }));
    const name = item.displayName || item.id;
    const seen = new Set();
    const add = (displayName, params, detail = item.description ?? '') => {
      if (!valid(params) || seen.has(key(params))) return;
      seen.add(key(params));
      const fast = params.find(p => p.id === 'fast');
      // Some real catalogs call BOTH variants "Composer 2.5", including
      // the fast=true variant. The effective parameters, not that ambiguous
      // display name or default position, must tell the user which speed wins.
      let parts = displayName.split(' · ').map(part => {
        const value = part.trim();
        return value.startsWith(name) ? value.slice(name.length).trim() : value;
      }).filter(Boolean);
      // Variant names are not unique: Grok publishes all four effort levels
      // with the same name. Surface every effective non-speed parameter.
      for (const param of params.filter(p => p.id !== 'fast')) {
        const definition = definitions.find(d => d.id === param.id);
        const value = definition?.values.find(v => String(v.value) === param.value);
        const parameterName = definition?.displayName || param.id;
        const valueName = value?.displayName || param.value;
        parts.push(`${parameterName}: ${valueName}`);
      }
      if (fast && ['true', 'false'].includes(fast.value)) {
        parts = parts.filter(part => !/^(?:fast|standard|fast\s*:\s*(?:true|false))$/i.test(part));
        parts.push(fast.value === 'true' ? 'Fast' : 'Standard');
      }
      const label = [name, ...new Set(parts)].join(' · ');
      result.push(model(item.id, label, detail, params));
    };
    add(name, merge([]));
    for (const variant of variants) add(`${name} · ${variant.displayName || key(variant.params)}`, merge(variant.params), variant.description ?? item.description ?? '');
    // Expose allowed parameter choices even if a provider omits named variants.
    // Each choice carries an explicit baseline for other parameters (including Router mode).
    for (const definition of definitions) {
      for (const value of definition.values) {
        const label = value.displayName || `${definition.displayName || definition.id}: ${value.value}`;
        add(`${name} · ${label}`, merge([{ id: definition.id, value: String(value.value) }]));
      }
    }
  }
  return result;
}

export function grokChoices(output) {
  const plain = output.replace(/\x1b\[[0-9;]*m/g, '');
  const lines = plain.split(/\r?\n/);
  let inList = false;
  const choices = [];
  for (const line of lines) {
    if (/^Available models:\s*$/.test(line.trim())) { inList = true; continue; }
    if (!inList) continue;
    const match = line.match(/^\s*[*-]\s+([A-Za-z0-9][A-Za-z0-9._:/-]*)(?:\s+\(default\))?\s*$/);
    if (match) choices.push(model(match[1], match[1], line.includes('(default)') ? 'Account default' : 'Grok account'));
  }
  if (!choices.length) throw Error('invalid_catalog');
  return choices;
}

export async function codexChoices(executable, { spawnProcess = spawn, timeout = 22000 } = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env };
    delete env.OPENAI_API_KEY;
    const child = spawnProcess(executable, ['app-server', '--listen', 'stdio://', '-c', 'model_provider="openai"',
      '--disable', 'plugins', '--disable', 'apps', '--disable', 'hooks'], {
      cwd: process.cwd(), env, detached: process.platform !== 'win32', stdio: ['pipe', 'pipe', 'pipe'],
    });
    let done = false, buffer = '', bytes = 0, requestID = 0, pages = 0;
    const models = [];
    const stop = (error, result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      process.removeListener('SIGTERM', cancel);
      process.removeListener('SIGINT', cancel);
      child.stdin.end();
      const kill = signal => {
        try {
          if (process.platform !== 'win32' && child.pid) process.kill(-child.pid, signal);
          else child.kill(signal);
        } catch {}
      };
      let completed = false;
      const finish = () => {
        if (completed) return; completed = true;
        clearTimeout(force); clearTimeout(deadline);
        if (error) reject(error); else resolve(result);
      };
      const force = setTimeout(() => kill('SIGKILL'), 500);
      const deadline = setTimeout(finish, 1200);
      child.once('close', finish);
      kill('SIGTERM');
    };
    const cancel = () => stop(Error('cancelled'));
    const timer = setTimeout(() => stop(Error('timeout')), timeout);
    process.once('SIGTERM', cancel);
    process.once('SIGINT', cancel);
    const send = message => child.stdin.write(JSON.stringify(message) + '\n');
    child.on('error', () => stop(Error('cli_start_failed')));
    child.on('close', () => { if (!done) stop(Error('cli_closed')); });
    child.stdin.on('error', () => { if (!done) stop(Error('cli_input_closed')); });
    child.stderr.on('data', () => {}); // never relay auth/config diagnostics
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', text => {
      bytes += Buffer.byteLength(text);
      if (bytes > 1048576) { stop(Error('catalog_too_large')); return; }
      buffer += text;
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0 && !done) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        if (message.id !== requestID) continue;
        if (message.error) { stop(Error('catalog_rejected')); return; }
        if (requestID === 0) {
          send({ method: 'initialized', params: {} });
          requestID = 1;
          send({ id: requestID, method: 'model/list', params: { limit: 100, includeHidden: false } });
        } else {
          const page = message.result;
          if (!Array.isArray(page?.data)) { stop(Error('invalid_catalog')); return; }
          for (const item of page.data) {
            if (item.hidden || typeof item.model !== 'string') continue;
            const detail = [item.description, item.isDefault ? 'Account default' : null].filter(Boolean).join(' · ');
            models.push(model(item.model, item.displayName || item.model, detail));
          }
          if (page.nextCursor && ++pages < 20) {
            send({ id: ++requestID, method: 'model/list', params: { limit: 100, includeHidden: false, cursor: page.nextCursor } });
          } else { stop(null, models); }
        }
      }
    });
    send({ id: 0, method: 'initialize', params: { clientInfo: { name: 'voiceinput_model_catalog', title: 'VoiceInput', version: '1.0' } } });
  });
}

async function grokModels(executable) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env }; delete env.XAI_API_KEY;
    const child = spawn(executable, ['models'], { cwd: process.cwd(), env, stdio: ['ignore', 'pipe', 'pipe'] });
    let text = '', done = false;
    const finish = (error, value) => {
      if (done) return; done = true; clearTimeout(timer);
      process.removeListener('SIGTERM', cancel); process.removeListener('SIGINT', cancel);
      if (error) { child.kill('SIGTERM'); const force = setTimeout(() => child.kill('SIGKILL'), 500); force.unref(); reject(error); }
      else resolve(value);
    };
    const cancel = () => finish(Error('cancelled'));
    const timer = setTimeout(() => finish(Error('timeout')), 22000);
    process.once('SIGTERM', cancel); process.once('SIGINT', cancel);
    child.on('error', () => finish(Error('cli_start_failed')));
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => { text += chunk; if (Buffer.byteLength(text) > 1048576) finish(Error('catalog_too_large')); });
    child.stderr.on('data', () => {});
    child.on('close', code => {
      if (code !== 0) { finish(Error('catalog_rejected')); return; }
      try { finish(null, grokChoices(text)); } catch (error) { finish(error); }
    });
  });
}

async function main() {
  const output = process.stdout.write.bind(process.stdout);
  const diagnostic = process.stderr.write.bind(process.stderr);
  const silence = (_chunk, encoding, callback) => { if (typeof encoding === 'function') encoding(); else if (typeof callback === 'function') callback(); return true; };
  process.stdout.write = silence; process.stderr.write = silence;
  try {
    process.stdin.setEncoding('utf8');
    let input = '';
    for await (const text of process.stdin) { input += text; if (Buffer.byteLength(input) > 65536) throw Error('invalid_request'); }
    const request = JSON.parse(input);
    let choices;
    if (request.provider === 'cursor') {
      if (typeof request.apiKey !== 'string' || !request.apiKey || !isAbsolute(request.sdkDirectory ?? '')) throw Error('invalid_request');
      const manifest = JSON.parse(await readFile(join(request.sdkDirectory, 'node_modules/@cursor/sdk/package.json'), 'utf8'));
      if (manifest.name !== '@cursor/sdk' || manifest.version !== '1.0.31') throw Error('sdk_version');
      delete process.env.CURSOR_BACKEND_URL; delete process.env.CURSOR_WEBSITE_URL;
      const require = createRequire(join(request.sdkDirectory, 'package.json'));
      const { Cursor } = require('@cursor/sdk');
      choices = cursorChoices(await Cursor.models.list({ apiKey: request.apiKey }));
    } else {
      if (!isAbsolute(request.executable ?? '')) throw Error('invalid_request');
      if (request.provider === 'codex') choices = await codexChoices(request.executable);
      else if (request.provider === 'grok') choices = await grokModels(request.executable);
      else throw Error('invalid_request');
    }
    const data = JSON.stringify(choices);
    if (Buffer.byteLength(data) > 1048576) throw Error('catalog_too_large');
    output(data, () => process.exit(0));
  } catch {
    diagnostic('Model discovery failed. Check provider sign-in, SDK installation and connectivity.\n', () => process.exit(1));
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
