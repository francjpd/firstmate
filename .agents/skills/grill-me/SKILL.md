---
name: grill-me
description: >-
  Grill the user relentlessly about a plan, decision, or idea to sharpen it before building.
  Use when the user asks to "grill an idea", "let's grill an idea", "lets grill an idea",
  "grill me", "stress-test this idea", or uses any 'grill' trigger phrases.
user-invocable: true
---

# Grilling (Matt Pocock's Grill Me Skill with Lavish Integration)

Interview the user relentlessly until you reach a shared understanding.
Map the problem space as a **design tree**: every decision branches into the decisions that hang off it.

## Execution Modes

1. **Visual Board Mode (`lavish-axi`) (Default)**:
   - Launch or resume persistent Lavish session with `bin/fm-grill.sh open <slug>`.
   - Renders live interactive Mermaid whiteboard decision tree and question cards.
   - Updates the DOM in place between rounds without reloading the browser tab: `bin/fm-grill.sh render <slug>`.
   - Focus-aware polling: long-polling in the browser client runs only while the tab has user focus (`document.visibilityState === 'visible'`), suspending when blurred.
   - Dual-channel input: accept choices either via Lavish option button clicks / form submission or terminal chat replies.
   - Persist session state to `data/grill/<slug>.json` after every round for cold-resume crash safety.

2. **Terminal Chat Mode (Fallback or with `--text`)**:
   - Run the interview directly in chat using the formatted rounds below.

## Orchestration Tooling (bin/fm-grill.sh)

- `bin/fm-grill.sh init <slug> "<title>"`: Initialize state in `data/grill/<slug>.json` and generate `.lavish/grill-<slug>.html`.
- `bin/fm-grill.sh render <slug>`: Re-render `.lavish/grill-<slug>.html` from current state after updating nodes or frontier.
- `bin/fm-grill.sh open <slug>`: Re-render and launch/resume Lavish session.
- `bin/fm-grill.sh poll <slug>`: Bounded wait for reviewer feedback from Lavish board.
- `bin/fm-grill.sh export <slug> [out]`: Export self-contained standalone HTML artifact.
- `bin/fm-grill.sh slice <slug>`: Slice agreed roadmap into Firstmate backlog tasks using `tasks-axi add`.

## Working the Design Tree

Work the tree in **rounds**.
The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet.
Ask the whole frontier in one round: number each question and give your recommended answer.
Then wait for the user's answers before computing the next round.

Format a chat round like so:

```markdown
❓ **Q1** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>

---

❓ **Q2** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>
```

Word each question so "yes" accepts your recommended answer.

Each round the user answers reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them.
Recompute the frontier and ask the next round.
A question whose answer depends on another question still open in this round belongs to a _later_ round, not this one.

## Fact-Finding vs Decisions

Finding _facts_ is your job, never the user's.
When a frontier question needs a fact from the environment (filesystem, dependencies, configs, tools), dispatch a sub-agent or run tool checks to find it.
Do not ask the user for anything you could look up yourself.
Embed discovered citations and code snippets directly inside the question card's collapsible evidence drawer.
The _decisions_ are the user's: put each to them and wait.

## Completion and Handoff

The interview is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed.
Do not act on the plan until the user confirms you have reached a shared understanding.
Present the final Alignment Summary in chat for the captain's explicit approval.
Upon approval:
- Compile a committed Markdown specification (ADR + RFC format) to `docs/` or `SPEC.md`.
- Export the persistent interactive Lavish HTML decision log with `bin/fm-grill.sh export <slug>`.
- Slice the agreed implementation roadmap into discrete Firstmate backlog tasks with `bin/fm-grill.sh slice <slug>` or `tasks-axi add`.
