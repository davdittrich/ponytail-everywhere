#!/usr/bin/env node
'use strict';

const fs = require('node:fs');

try {
  const hooks = JSON.parse(fs.readFileSync(0, 'utf8')).activeHooks;
  const hook = Array.isArray(hooks) && hooks.find((entry) =>
    entry?.capId === 'ponytail'
    && entry.kind === 'contribution'
    && entry.into === 'planner'
    && typeof entry.fragment?.inline === 'string'
  );
  if (hook) process.stdout.write(`${hook.fragment.inline.replace(/\n*$/, '')}\n`);
} catch {
  // Capability contributions declare onError: skip.
}
