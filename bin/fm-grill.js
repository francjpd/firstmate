#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { renderHtml } from './fm-grill-lib.js';

function usage() {
  console.log(`fm-grill - Orchestration helper for Grill Me + Lavish & deck-axi integration

USAGE:
  fm-grill init <slug> "<title>"     Initialize a new session in data/grill/<slug>.json
  fm-grill render <slug>             Render/update .lavish/grill-<slug>.html from state
  fm-grill open <slug>               Render and open interactive board with lavish-axi
  fm-grill tui <slug>                Open terminal interactive cockpit with deck-axi
  fm-grill poll <slug>               Poll lavish-axi for reviewer feedback
  fm-grill export <slug> [out-file]  Export self-contained standalone HTML artifact
  fm-grill slice <slug>              Slice agreed roadmap into Firstmate backlog tasks
`);
  process.exit(1);
}

const command = process.argv[2];
const slug = process.argv[3];

if (!command || !slug || command === '-h' || command === '--help') {
  usage();
}

const stateDir = path.resolve('data/grill');
const lavishDir = path.resolve('.lavish');
const jsonPath = path.join(stateDir, `${slug}.json`);
const htmlPath = path.join(lavishDir, `grill-${slug}.html`);

fs.mkdirSync(stateDir, { recursive: true });
fs.mkdirSync(lavishDir, { recursive: true });

function loadSession() {
  if (!fs.existsSync(jsonPath)) {
    console.error(`error: session file ${jsonPath} not found`);
    process.exit(1);
  }
  return JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
}

switch (command) {
  case 'init': {
    const title = process.argv[4] || 'Architecture Decision Tree';
    const initialSession = {
      slug,
      title,
      round: 1,
      status: 'active',
      nodes: [
        { id: 'root', title, state: 'frontier' }
      ],
      frontier: [
        {
          id: 'Q1',
          title: 'Initial Architectural Direction',
          body: 'Choose the primary interaction model for the feature.',
          options: [
            { key: '1', label: 'Terminal-native React Ink cockpit (deck-axi)', recommended: true },
            { key: '2', label: 'Visual Browser Board (Lavish Editor)', recommended: false }
          ]
        }
      ],
      settled: []
    };
    fs.writeFileSync(jsonPath, JSON.stringify(initialSession, null, 2), 'utf8');
    const html = renderHtml(initialSession);
    fs.writeFileSync(htmlPath, html, 'utf8');
    console.log(`Initialized grill session:`);
    console.log(`  State: ${jsonPath}`);
    console.log(`  HTML:  ${htmlPath}`);
    break;
  }

  case 'render': {
    const session = loadSession();
    const html = renderHtml(session);
    fs.writeFileSync(htmlPath, html, 'utf8');
    console.log(`Rendered .lavish/grill-${slug}.html for Round ${session.round} (${session.status})`);
    break;
  }

  case 'open': {
    const session = loadSession();
    const html = renderHtml(session);
    fs.writeFileSync(htmlPath, html, 'utf8');
    console.log(`Opening Lavish board: ${htmlPath}`);
    execFileSync('lavish-axi', [htmlPath], { stdio: 'inherit' });
    break;
  }

  case 'tui': {
    const deckLauncher = path.join(__dirname, 'fm-deck.sh');
    const bin = fs.existsSync(deckLauncher) ? deckLauncher : 'deck-axi';
    console.log(`Launching ${bin} TUI for ${jsonPath}`);
    execFileSync(bin, ['grill', jsonPath], { stdio: 'inherit' });
    break;
  }

  case 'poll': {
    console.log(`Polling lavish-axi for feedback on ${htmlPath}...`);
    try {
      const out = execFileSync('lavish-axi', ['poll', htmlPath], { encoding: 'utf8' });
      process.stdout.write(out);
    } catch (err) {
      console.error('lavish-axi poll ended:', err instanceof Error ? err.message : String(err));
    }
    break;
  }

  case 'export': {
    const outFile = process.argv[4] || path.join(lavishDir, `grill-${slug}-final.html`);
    console.log(`Exporting standalone HTML to ${outFile}...`);
    execFileSync('lavish-axi', ['export', htmlPath, '--out', outFile], { stdio: 'inherit' });
    break;
  }

  case 'slice': {
    const session = loadSession();
    const roadmap = session.roadmap || [];
    if (!Array.isArray(roadmap) || roadmap.length === 0) {
      console.log('No roadmap items found in session to slice.');
      break;
    }
    console.log(`Slicing ${roadmap.length} tasks into Firstmate backlog:`);
    for (const item of roadmap) {
      const taskId = item.id || `grill-${slug}-${Math.random().toString(36).slice(2, 6)}`;
      const title = item.title || 'Roadmap item';
      const kind = item.kind || 'ship';
      const blockedBy = item.blockedBy;
      const cmd = ['bin/fm-tasks-axi.sh', 'add', taskId, title, '--kind', kind];
      if (blockedBy) {
        cmd.push('--blocked-by', blockedBy);
      }
      try {
        execFileSync(cmd[0], cmd.slice(1), { stdio: 'inherit' });
      } catch (err) {
        console.error(`Failed to add task ${taskId}:`, err instanceof Error ? err.message : String(err));
      }
    }
    break;
  }

  default:
    console.error(`unknown command: ${command}`);
    usage();
}
