import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { cursorChoices, grokChoices, codexChoices } from '../../Sources/VoiceInput/Resources/provider-models.mjs';

test('Cursor Fast uses the discovered model ID and actual fast parameter', () => {
  const choices = cursorChoices([{ id: 'composer-2.5', displayName: 'Composer 2.5',
    parameters: [{ id: 'fast', displayName: 'Fast', values: [{ value: 'false' }, { value: 'true', displayName: 'Fast' }] }] }]);
  assert.equal(choices.length, 2);
  const fast = choices.find(c => c.parameters.some(p => p.value === 'true'));
  assert.equal(fast.modelID, 'composer-2.5');
  assert.match(fast.displayName, /Fast/);
  assert.deepEqual(fast.parameters, [{ id: 'fast', value: 'true' }]);
  assert.ok(!choices.some(c => c.modelID === 'composer-2-fast'));
});

test('Cursor named variants retain other explicit parameter values', () => {
  const choices = cursorChoices([{ id: 'router', displayName: 'Router',
    parameters: [
      { id: 'optimize_for', values: [{ value: 'balanced' }, { value: 'cost' }] },
      { id: 'fast', values: [{ value: 'false' }, { value: 'true' }] },
    ], variants: [{ displayName: 'Economy', params: [{ id: 'optimize_for', value: 'cost' }] }] }]);
  const economy = choices.find(c => c.displayName.includes('Economy'));
  assert.deepEqual(economy.parameters, [{ id: 'optimize_for', value: 'cost' }, { id: 'fast', value: 'false' }]);
  assert.equal(new Set(choices.map(c => JSON.stringify(c.parameters))).size, choices.length);
});

test('Grok parser accepts only the models section, not log lines or prose', () => {
  const choices = grokChoices('You are logged in.\nDefault model: grok-4.6\n\nAvailable models:\n  * grok-4.6 (default)\n  - grok-4.5\nERROR fetch failed\n');
  assert.deepEqual(choices.map(c => c.modelID), ['grok-4.6', 'grok-4.5']);
  assert.throws(() => grokChoices('Account unavailable\n'), /invalid_catalog/);
});

test('Codex metadata follows initialization and pagination without starting a thread', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'voiceinput-codex-model-test-'));
  try {
    const executable = join(directory, 'fake-codex');
    await writeFile(executable, `#!${process.execPath}
      const readline = require('node:readline');
      let initialized = false;
      readline.createInterface({input:process.stdin}).on('line', line => {
        const m = JSON.parse(line);
        if (m.method === 'initialize') process.stdout.write(JSON.stringify({id:m.id,result:{}})+'\\n');
        else if (m.method === 'initialized') initialized = true;
        else if (m.method === 'model/list' && initialized) process.stdout.write(JSON.stringify({id:m.id,result:{
          data: m.params.cursor ? [{id:'two',model:'model-two',displayName:'Second'}] : [{id:'one',model:'model-one',displayName:'First'}, {model:'hidden',hidden:true}],
          nextCursor: m.params.cursor ? null : 'page-two'
        }})+'\\n');
        else { process.stderr.write('unexpected generation method'); process.exit(9); }
      });
    `);
    await chmod(executable, 0o700);
    const choices = await codexChoices(executable, { timeout: 3000 });
    assert.deepEqual(choices.map(c => c.modelID), ['model-one', 'model-two']);
  } finally { await rm(directory, { recursive: true, force: true }); }
});


test('real Composer catalog with fast=true first and duplicate variant names stays explicit', () => {
  const choices = cursorChoices([{ id: 'composer-2.5', displayName: 'Composer 2.5',
    parameters: [{ id: 'fast', displayName: 'Fast', values: [{ value: 'true' }, { value: 'false' }] }],
    variants: [
      { displayName: 'Composer 2.5', isDefault: true, params: [{ id: 'fast', value: 'true' }] },
      { displayName: 'Composer 2.5', params: [{ id: 'fast', value: 'false' }] },
    ] }]);
  assert.equal(choices.length, 2);
  assert.deepEqual(choices.map(c => c.displayName), ['Composer 2.5 · Fast', 'Composer 2.5 · Standard']);
  assert.deepEqual(choices.map(c => c.parameters[0].value), ['true', 'false']);
  assert.ok(!choices.some(c => c.displayName.includes('Composer 2.5 · Composer 2.5')));
});

test('Grok effort × speed variants have distinct visible names and retain all parameters', () => {
  const variants = ['low', 'medium', 'high', 'xhigh'].flatMap(effort => ['true', 'false'].map(fast => ({
    displayName: 'Cursor Grok 4.6', params: [{ id: 'effort', value: effort }, { id: 'fast', value: fast }],
  })));
  const choices = cursorChoices([{ id: 'grok-4.6', displayName: 'Cursor Grok 4.6', parameters: [
    { id: 'effort', values: ['low', 'medium', 'high', 'xhigh'].map(value => ({ value })) },
    { id: 'fast', values: [{ value: 'true' }, { value: 'false' }] },
  ], variants }]);
  assert.equal(choices.length, 8);
  assert.equal(new Set(choices.map(c => c.displayName)).size, 8);
  for (const row of choices) {
    const p = Object.fromEntries(row.parameters.map(p => [p.id, p.value]));
    assert.ok(row.displayName.includes(`effort: ${p.effort}`));
    assert.ok(row.displayName.endsWith(p.fast === 'true' ? 'Fast' : 'Standard'));
  }
});
