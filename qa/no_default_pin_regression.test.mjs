import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const sourceFiles = [
  '../src/services/offlineStore.ts',
  '../web_simulation/src/services/offlineStore.ts',
].map((path) => new URL(path, import.meta.url));
const dialogFiles = [
  '../src/components/PinExitDialog.tsx',
  '../web_simulation/src/components/PinExitDialog.tsx',
].map((path) => new URL(path, import.meta.url));
const existingSources = sourceFiles.filter((file) => existsSync(file));
const existingDialogs = dialogFiles.filter((file) => existsSync(file));

assert.ok(existingSources.length > 0, 'persisted-state source was not found');
assert.ok(existingDialogs.length > 0, 'PIN dialog source was not found');

for (const file of existingSources) {
  const offlineStore = readFileSync(file, 'utf8');
  assert.doesNotMatch(offlineStore, /2468/);
  assert.match(
    offlineStore,
    /lecturerPin:\s*rawPin\s*&&\s*\/\^\\d\{4\}\$\/\.test\(rawPin\)\s*\?\s*rawPin\s*:\s*''/,
  );
  assert.match(offlineStore, /lecturerPin:\s*''/);
}

for (const file of existingDialogs) {
  const pinDialog = readFileSync(file, 'utf8');
  assert.doesNotMatch(pinDialog, /2468|Default PIN/i);
  assert.match(pinDialog, /lecturer PIN configured in Teacher Monitor/);
}

console.log('PASS: missing, invalid, and unreadable PIN state has no default PIN');
