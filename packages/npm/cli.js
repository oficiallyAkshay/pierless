#!/usr/bin/env node
// A wrapper, not the shell script itself: npm installs a `bin` entry as a
// symlink in node_modules/.bin, and bin/pierless locates install-runner.sh,
// deploy.sh and ../templates through ${BASH_SOURCE[0]} — which under that
// symlink resolves to the .bin directory, where it has no siblings. Spawning
// bash on the real bundled path keeps those relative lookups correct.
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const cli = path.join(__dirname, 'bin', 'pierless');
const result = spawnSync('bash', [cli, ...process.argv.slice(2)], { stdio: 'inherit' });

if (result.error) {
  process.stderr.write(`pierless: could not run bash: ${result.error.message}\n`);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
