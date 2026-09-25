#!/usr/bin/env node

import { runCLI } from '../lib/cli.mjs';

process.exitCode = await runCLI(process.argv.slice(2));
