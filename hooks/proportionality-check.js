#!/usr/bin/env node

const { spawnSync } = require('child_process');
const path = require('path');

const commands = new Map([
  ['gsd-new-project', 'milestone'],
  ['gsd-new-milestone', 'milestone'],
  ['gsd-manager', 'milestone'],
  ['gsd-mvp-phase', 'phase'],
  ['gsd-discuss-phase', 'phase'],
]);
const rank = { direct: 0, quick: 1, phase: 2, milestone: 3 };

function readInput() {
  try {
    return JSON.parse(require('fs').readFileSync(0, 'utf8'));
  } catch {
    return null;
  }
}

function getConfig(cwd, key, fallback) {
  const helper = path.join(process.env.CLAUDE_PLUGIN_ROOT || path.join(__dirname, '..'), 'hooks', 'gsd-tools.sh');
  const result = spawnSync('bash', [
    '-c',
    '. "$1"; gsd_tools config-get "$2" --default "$3"',
    'ponytail-config', helper, key, fallback,
  ], { cwd, encoding: 'utf8', timeout: 3000 });
  return result.status === 0 ? result.stdout.trim().replace(/^"|"$/g, '') : fallback;
}

function classify(text) {
  if (/\b(new (project|milestone)|milestone|roadmap|multiple phases|several phases)\b/i.test(text)) return 'milestone';
  if (/\b(review|explain|diagnos(?:e|is)|investigat(?:e|ion)|read[ -]?only)\b/i.test(text)) return 'direct';
  return 'ambiguous';
}

const input = readInput();
if (!input || input.hook_event_name !== 'UserPromptExpansion' || !commands.has(input.command_name)) process.exit(0);

const cwd = typeof input.cwd === 'string' ? input.cwd : process.cwd();
if (getConfig(cwd, 'ponytail.enabled', 'true') === 'false') process.exit(0);

const enforcementValue = getConfig(cwd, 'ponytail.enforcement', 'warn');
const enforcement = ['advisory', 'warn', 'block'].includes(enforcementValue) ? enforcementValue : 'warn';
const text = [input.command_args, input.prompt].filter(value => typeof value === 'string').join('\n').slice(0, 4000);
const route = classify(text);
if (route === 'ambiguous' || rank[route] >= rank[commands.get(input.command_name)]) process.exit(0);

const choices = 'direct, quick, phase, or milestone';
const recommendation = `Ponytail recommends the ${route} route. Resubmit explicitly as ${choices}.`;
if (enforcement === 'advisory') {
  process.stdout.write(JSON.stringify({ additionalContext: recommendation }));
} else {
  process.stdout.write(JSON.stringify({ decision: 'block', reason: recommendation }));
}
