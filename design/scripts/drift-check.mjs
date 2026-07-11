import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);

const readArg = (name, fallback) => {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  return args[index + 1] ?? fallback;
};

const strict = args.includes('--strict');
const defaultTarget = resolve(root, '..', '..', 'clashking-app');
const target = resolve(readArg('--target', defaultTarget));
const libRoot = join(target, 'lib');

const ignorePathParts = [
  `${join('lib', 'l10n')}`,
  '.dart_tool',
  'build',
  '.git',
  '.claude',
  '.agents',
];

const allowedRawColorFiles = new Set([
  join('lib', 'core', 'app', 'my_app.dart'),
  join('lib', 'common', 'theme', 'app_tokens.dart'),
]);

const checks = [
  {
    id: 'raw_hex_color',
    severity: 'high',
    description: 'Raw Color(0x...) values outside theme/token files',
    pattern: /(?:const\s+)?Color\(\s*0x[0-9A-Fa-f]{8}\s*\)/g,
    allow: (file) => allowedRawColorFiles.has(file),
    recommendation:
      'Move recurring values to CKColors/StatColors or use ColorScheme roles.',
  },
  {
    id: 'raw_material_color',
    severity: 'medium',
    description: 'Colors.* usages that may bypass semantic theme/tokens',
    pattern: /(?<![A-Za-z0-9_])Colors\.[A-Za-z0-9_]+/g,
    allow: (file, match) =>
      allowedRawColorFiles.has(file) ||
      ['Colors.transparent'].includes(match),
    recommendation:
      'Prefer Theme.of(context).colorScheme, CKColors, or StatColors for recurring values.',
  },
  {
    id: 'literal_radius',
    severity: 'high',
    description: 'BorderRadius.circular(number) literals',
    pattern: /BorderRadius\.circular\(\s*(\d+(?:\.\d+)?)\s*\)/g,
    allow: (_file, _match, groups) =>
      ['12', '16', '20', '28', '999'].includes(groups[0]),
    recommendation:
      'Use CKRadius/AppRadius. If the literal is intentional, it should fit 12/16/20/28/999.',
  },
  {
    id: 'literal_spacing',
    severity: 'medium',
    description: 'EdgeInsets literals in app UI',
    pattern:
      /EdgeInsets\.(?:all|symmetric|only|fromLTRB)\(\s*(?:const\s+)?[^)]*\)/g,
    allow: () => false,
    recommendation:
      'Prefer CKSpacing for shared/reusable primitives; migrate app screens opportunistically.',
  },
  {
    id: 'emoji_icon',
    severity: 'high',
    description: 'Emoji-like structural icons in Dart UI',
    pattern:
      /['"][^'"\n]*(?:🏆|⭐|🥇|🥈|🥉|⚔️|⚔|🛡️|🛡|🎯|🔥|💎|🏅)[^'"\n]*['"]/gu,
    allow: () => false,
    recommendation:
      'Replace structural emoji with Material or lucide_icons_flutter icons.',
  },
];

const iconButtonPattern = /(?<![A-Za-z0-9_])IconButton\s*\(/g;
const tooltipPattern = /\btooltip\s*:/;

const walk = (dir, files = []) => {
  if (!existsSync(dir)) return files;
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    const relativePath = relative(target, path);
    if (ignorePathParts.some((part) => relativePath.includes(part))) continue;
    const stats = statSync(path);
    if (stats.isDirectory()) walk(path, files);
    else if (path.endsWith('.dart')) files.push(path);
  }
  return files;
};

const lineForIndex = (content, index) =>
  content.slice(0, index).split(/\r?\n/).length;

const summarize = (matches) => {
  const byFile = new Map();
  for (const match of matches) {
    const fileMatches = byFile.get(match.file) ?? [];
    fileMatches.push(match);
    byFile.set(match.file, fileMatches);
  }

  return [...byFile.entries()]
    .map(([file, fileMatches]) => ({
      file,
      count: fileMatches.length,
      lines: fileMatches.slice(0, 8).map((match) => match.line),
    }))
    .sort((a, b) => b.count - a.count || a.file.localeCompare(b.file));
};

if (!existsSync(libRoot)) {
  console.error(`Design drift target is missing a lib directory: ${target}`);
  process.exit(2);
}

const files = walk(libRoot);
const results = [];

for (const check of checks) {
  const matches = [];
  for (const filePath of files) {
    const rel = relative(target, filePath);
    const content = readFileSync(filePath, 'utf8');
    for (const match of content.matchAll(check.pattern)) {
      if (check.allow(rel, match[0], match.slice(1))) continue;
      matches.push({
        file: rel,
        line: lineForIndex(content, match.index ?? 0),
        text: match[0],
      });
    }
  }
  results.push({ ...check, matches, summary: summarize(matches) });
}

const iconButtonMatches = [];
for (const filePath of files) {
  const rel = relative(target, filePath);
  const content = readFileSync(filePath, 'utf8');
  for (const match of content.matchAll(iconButtonPattern)) {
    const start = match.index ?? 0;
    const window = content.slice(start, start + 700);
    if (tooltipPattern.test(window)) continue;
    iconButtonMatches.push({
      file: rel,
      line: lineForIndex(content, start),
      text: 'IconButton(...)',
    });
  }
}

results.push({
  id: 'icon_button_missing_tooltip',
  severity: 'high',
  description: 'IconButton calls without nearby tooltip:',
  recommendation:
    'Add tooltip: for icon-only buttons, or wrap custom controls in Tooltip/Semantics.',
  matches: iconButtonMatches,
  summary: summarize(iconButtonMatches),
});

console.log(`Design drift check target: ${target}`);
console.log(`Mode: ${strict ? 'strict' : 'warning'}\n`);

let total = 0;
let high = 0;

for (const result of results) {
  const count = result.matches.length;
  total += count;
  if (result.severity === 'high') high += count;

  console.log(
    `[${result.severity.toUpperCase()}] ${result.id}: ${count} finding(s)`,
  );
  console.log(`  ${result.description}`);
  console.log(`  ${result.recommendation}`);
  for (const file of result.summary.slice(0, 10)) {
    console.log(`  - ${file.file}: ${file.count} (${file.lines.join(', ')})`);
  }
  if (result.summary.length > 10) {
    console.log(`  ... ${result.summary.length - 10} more files`);
  }
  console.log('');
}

console.log(`Total findings: ${total}`);
console.log(`High severity findings: ${high}`);

if (strict && high > 0) {
  console.error('\nDesign drift strict mode failed because high severity findings exist.');
  process.exit(1);
}
