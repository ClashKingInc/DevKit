import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (path) => readFileSync(join(root, path), 'utf8');
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const workspace = JSON.parse(read('package.json'));
const cssPackage = JSON.parse(read('packages/css/package.json'));

assert(workspace.workspaces.includes('packages/css'), 'CSS workspace is not registered');

for (const exportedPath of Object.values(cssPackage.exports)) {
  const relativePath = `packages/css/${exportedPath.replace(/^\.\//, '')}`;
  assert(existsSync(join(root, relativePath)), `Missing CSS export: ${relativePath}`);
}

const indexCss = read('packages/css/index.css');
for (const match of indexCss.matchAll(/@import\s+['"]([^'"]+)['"]/g)) {
  const relativePath = `packages/css/${match[1].replace(/^\.\//, '')}`;
  assert(existsSync(join(root, relativePath)), `Missing CSS import: ${relativePath}`);
}

const tokens = read('packages/css/tokens.css');
for (const token of [
  '--ck-color-primary-red',
  '--ck-color-secondary-blue',
  '--ck-color-legend-blue',
  '--ck-color-discord-blurple',
  '--ck-radius-control',
  '--ck-radius-panel',
]) {
  assert(tokens.includes(token), `Missing required CSS token: ${token}`);
}

const flutterTokens = read('packages/flutter/lib/clashking_design_system.dart');
for (const className of ['CKColors', 'CKRadius', 'CKOpacity', 'CKSpacing']) {
  assert(flutterTokens.includes(`class ${className}`), `Missing Flutter token class: ${className}`);
}

for (const className of [
  'CKMetricChip',
  'CKMetricChipGrid',
  'CKStatTile',
  'CKGlassPanel',
  'CKSegmentedControl',
]) {
  assert(flutterTokens.includes(`class ${className}`), `Missing Flutter primitive: ${className}`);
}

for (const docPath of [
  'CHANGELOG.md',
  'docs/MASTER.md',
  'docs/flutter.md',
  'docs/components.md',
  'docs/drift-checks.md',
  'docs/governance.md',
]) {
  assert(existsSync(join(root, docPath)), `Missing design documentation: ${docPath}`);
}

console.log('Design manifests, exports, imports, and required tokens are valid');
