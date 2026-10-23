#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

export function renderMermaidGraph(nodes) {
  if (!nodes || nodes.length === 0) {
    return 'graph TD\n  root["Decision Tree Root"]\n';
  }

  const lines = ['graph TD'];
  const nodeMap = new Map();

  for (const n of nodes) {
    nodeMap.set(n.id, n);
    let label = n.title.replace(/"/g, "'");
    if (n.chosenOutcome) {
      label += `\\n✓ ${n.chosenOutcome.replace(/"/g, "'")}`;
    }
    lines.push(`  ${n.id}["${label}"]`);
  }

  for (const n of nodes) {
    if (n.parentId && nodeMap.has(n.parentId)) {
      lines.push(`  ${n.parentId} --> ${n.id}`);
    }
  }

  // Styles
  lines.push('  classDef settled fill:#2e7d32,stroke:#4caf50,stroke-width:2px,color:#fff;');
  lines.push('  classDef frontier fill:#f57f17,stroke:#ffb300,stroke-width:2px,color:#fff;');
  lines.push('  classDef pending fill:#374151,stroke:#6b7280,stroke-width:1px,color:#9ca3af;');

  for (const n of nodes) {
    if (n.state === 'settled') {
      lines.push(`  class ${n.id} settled;`);
    } else if (n.state === 'frontier') {
      lines.push(`  class ${n.id} frontier;`);
    } else {
      lines.push(`  class ${n.id} pending;`);
    }
  }

  return lines.join('\n');
}

export function renderHtml(session) {
  const slug = session.slug || 'grill-session';
  const title = session.title || 'Grill Me Decision Board';
  const round = session.round || 1;
  const status = (session.status || 'active').toUpperCase();
  const frontier = session.frontier || [];
  const settled = session.settled || [];
  const nodes = session.nodes || [];

  const mermaidGraph = renderMermaidGraph(nodes);

  return `<!DOCTYPE html>
<html lang="en" data-lavish-annotate="off" data-theme="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title} - Round ${round}</title>
  <!-- Tailwind CSS & DaisyUI via Lavish CDN -->
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/themes.css">
  <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js"></script>
  <!-- Mermaid -->
  <script type="module">
    import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11.15.0/dist/mermaid.esm.min.mjs";
    mermaid.initialize({ startOnLoad: true, theme: 'dark' });
  </script>
  <!-- Layout Safety & Custom Styles -->
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    :where(.grid, .flex, .layout-grid, .layout-flex) > * { min-width: 0; }
    :where(p, h1, h2, h3, h4, h5, h6, li, dd, blockquote, td, th) { overflow-wrap: anywhere; }
    .mermaid { background: #18181b; padding: 1.5rem; border-radius: 0.75rem; border: 1px solid #27272a; overflow-x: auto; }
    .option-pill.active { border-color: #3b82f6; background-color: rgba(59, 130, 246, 0.15); }
    .option-pill.recommended { border-color: #22c55e; }
  </style>
  <!-- Focus-Aware Polling Script -->
  <script>
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        console.log('[grill-lavish] Tab became visible. Resuming active polling.');
        if (window.lavish && typeof window.lavish.resumePolling === 'function') {
          window.lavish.resumePolling();
        }
      } else {
        console.log('[grill-lavish] Tab hidden. Suspending background HTTP polling.');
        if (window.lavish && typeof window.lavish.suspendPolling === 'function') {
          window.lavish.suspendPolling();
        }
      }
    });

    const stateAnswers = {};

    function selectOption(qid, key, label) {
      stateAnswers[qid] = stateAnswers[qid] || {};
      stateAnswers[qid].option = key;
      stateAnswers[qid].label = label;

      document.querySelectorAll('[data-qid="' + qid + '"] .option-pill').forEach(el => {
        el.classList.remove('active');
      });
      const selectedEl = document.querySelector('[data-qid="' + qid + '"][data-optkey="' + key + '"]');
      if (selectedEl) selectedEl.classList.add('active');
    }

    function acceptAllRecommended() {
      document.querySelectorAll('.option-pill.recommended').forEach(el => {
        const qid = el.getAttribute('data-qid');
        const key = el.getAttribute('data-optkey');
        const label = el.getAttribute('data-label');
        if (qid && key) {
          selectOption(qid, key, label);
        }
      });
    }

    function submitAllAnswers() {
      const answersText = [];
      document.querySelectorAll('[data-lavish-question]').forEach(qEl => {
        const qid = qEl.getAttribute('data-lavish-question');
        const customNote = qEl.querySelector('textarea')?.value?.trim();
        const chosen = stateAnswers[qid];

        if (chosen || customNote) {
          let line = qid + ': ' + (chosen ? chosen.key + ' (' + chosen.label + ')' : '(no option)');
          if (customNote) line += ' [Note: ' + customNote + ']';
          answersText.push(line);
        }
      });

      const promptText = 'Round ${round} decisions:\\n' + (answersText.length ? answersText.join('\\n') : 'Accepted recommended choices');
      if (window.lavish && typeof window.lavish.queuePrompt === 'function') {
        window.lavish.queuePrompt(promptText, {
          tag: 'grill-answers',
          data: { round: ${round}, answers: stateAnswers }
        });
        if (typeof window.lavish.sendQueuedPrompts === 'function') {
          window.lavish.sendQueuedPrompts();
        }
      } else {
        copyChatAnswers();
      }
    }

    function copyChatAnswers() {
      const answersText = [];
      document.querySelectorAll('[data-lavish-question]').forEach(qEl => {
        const qid = qEl.getAttribute('data-lavish-question');
        const customNote = qEl.querySelector('textarea')?.value?.trim();
        const chosen = stateAnswers[qid];
        if (chosen || customNote) {
          let line = qid + ': ' + (chosen ? chosen.label : '(custom)');
          if (customNote) line += ' [Note: ' + customNote + ']';
          answersText.push(line);
        }
      });
      const text = answersText.join('\\n') || 'yes (accept recommended)';
      navigator.clipboard.writeText(text).then(() => {
        const banner = document.getElementById('copy-feedback');
        if (banner) {
          banner.textContent = '✓ Answers copied to clipboard for terminal chat!';
          setTimeout(() => { banner.textContent = ''; }, 4000);
        }
      });
    }
  </script>
</head>
<body class="bg-base-300 text-base-content min-h-screen">
  <!-- Sticky Top Navbar -->
  <header class="navbar bg-base-100 shadow-md sticky top-0 z-50 px-4 border-b border-base-200">
    <div class="navbar-start gap-3">
      <span class="badge badge-primary font-bold">Grill Me</span>
      <h1 class="text-xl font-bold">${title}</h1>
      <span class="badge badge-warning">Round ${round}</span>
      <span class="badge badge-outline">${status}</span>
    </div>
    <div class="navbar-end gap-2">
      <button type="button" class="btn btn-sm btn-outline btn-success" onclick="acceptAllRecommended()">
        ✓ Accept All Recommended
      </button>
      <button type="button" class="btn btn-sm btn-primary" onclick="submitAllAnswers()">
        Submit Answers
      </button>
      <button type="button" class="btn btn-sm btn-ghost" onclick="copyChatAnswers()">
        Copy for Chat
      </button>
      <span id="copy-feedback" class="text-xs text-success font-medium"></span>
    </div>
  </header>

  <main class="max-w-6xl mx-auto p-6 space-y-8">
    <!-- Live Mermaid Whiteboard -->
    <section class="card bg-base-100 shadow p-6 space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-bold flex items-center gap-2">
          <span>🌿</span> Live Decision Tree
        </h2>
        <span class="text-xs text-base-content/60">Green = Settled • Amber = Active Frontier • Dimmed = Pending</span>
      </div>
      <div class="mermaid">
${mermaidGraph}
      </div>
    </section>

    <!-- Active Question Cards -->
    <section class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-bold flex items-center gap-2">
          <span>❓</span> Active Decision Frontier (${frontier.length} questions)
        </h2>
      </div>

      ${frontier.length === 0 ? `
        <div class="alert alert-success shadow">
          <span>✓ Frontier is empty! All decisions have been settled. Review the Alignment Summary in chat.</span>
        </div>
      ` : frontier.map((q, idx) => `
        <article class="card bg-base-100 shadow border border-base-200" data-lavish-question="${q.id}">
          <div class="card-body p-6 space-y-4">
            <div class="flex items-start justify-between">
              <div>
                <span class="badge badge-accent mb-2">Question ${idx + 1} of ${frontier.length} • ${q.id}</span>
                <h3 class="text-xl font-bold">${q.title}</h3>
              </div>
            </div>

            <p class="text-base-content/80 text-sm leading-relaxed">${q.body || ''}</p>

            <!-- Options Grid -->
            <div class="space-y-2">
              <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">Options:</h4>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                ${(q.options || []).map(opt => `
                  <button type="button"
                    class="option-pill p-3 rounded-lg border text-left transition flex items-start gap-3 cursor-pointer ${opt.recommended ? 'recommended' : 'border-base-300'}"
                    data-qid="${q.id}"
                    data-optkey="${opt.key}"
                    data-label="${opt.label}"
                    onclick="selectOption('${q.id}', '${opt.key}', '${opt.label.replace(/'/g, "\\'")}')">
                    <span class="badge badge-sm badge-neutral font-mono mt-0.5">${opt.key}</span>
                    <div class="flex-1">
                      <div class="font-medium flex items-center gap-2">
                        <span>${opt.label}</span>
                        ${opt.recommended ? '<span class="badge badge-xs badge-success font-semibold">Recommended</span>' : ''}
                      </div>
                      ${opt.summary ? '<p class="text-xs text-base-content/60 mt-1">' + opt.summary + '</p>' : ''}
                    </div>
                  </button>
                `).join('')}
              </div>
            </div>

            <!-- Collapsible Evidence Drawer -->
            ${q.evidence && q.evidence.length > 0 ? `
              <details class="collapse collapse-arrow bg-base-200/50 border border-base-300 rounded-lg">
                <summary class="collapse-title text-sm font-medium flex items-center gap-2">
                  <span>🔍</span> Evidence & Local Citations (${q.evidence.length} items)
                </summary>
                <div class="collapse-content text-xs space-y-2">
                  ${q.evidence.map(ev => `
                    <div class="p-2 bg-base-100 rounded border border-base-300">
                      <span class="font-semibold text-warning">${ev.label}:</span>
                      <pre class="mt-1 text-base-content/80 whitespace-pre-wrap font-mono">${ev.detail}</pre>
                    </div>
                  `).join('')}
                </div>
              </details>
            ` : ''}

            <!-- Custom Note Input -->
            <div class="space-y-1">
              <label class="text-xs font-semibold uppercase tracking-wider text-base-content/60">Custom Note or Counter-Proposal:</label>
              <textarea class="textarea textarea-bordered w-full text-sm" rows="2" placeholder="Optional notes, constraints, or caveats..."></textarea>
            </div>
          </div>
        </article>
      `).join('')}
    </section>

    <!-- Settled Decisions History -->
    ${settled && settled.length > 0 ? `
      <section class="card bg-base-100 shadow p-6 space-y-4">
        <h2 class="text-lg font-bold flex items-center gap-2">
          <span>📜</span> Settled Decisions History (${settled.length})
        </h2>
        <div class="divide-y divide-base-200">
          ${settled.map(s => `
            <div class="py-3 flex items-start justify-between">
              <div>
                <span class="font-bold text-sm text-base-content">${s.title}</span>
                ${s.rationale ? '<p class="text-xs text-base-content/60 mt-0.5">' + s.rationale + '</p>' : ''}
              </div>
              <span class="badge badge-success badge-sm font-semibold">${s.chosen}</span>
            </div>
          `).join('')}
        </div>
      </section>
    ` : ''}
  </main>
</body>
</html>
`;
}
