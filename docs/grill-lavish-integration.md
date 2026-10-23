# Grill Me and Lavish Integration Architecture Decision Record

This document defines the architecture and operational contract for integrating Matt Pocock's Grill Me interview workflow with the Lavish visual artifact editor.

## Context

Grill Me turns vague prompts into actionable design trees by interrogating the user across sequential decision frontiers before code is written.
Lavish Editor opens agent-generated HTML files in a local browser, providing element annotations and interactive Mermaid whiteboards.
Combining them replaces long terminal text interviews with an interactive visual decision board while keeping the terminal chat as the conversational orchestrator.

## Settled Decisions

### 1. Primary Interaction Surface
Lavish acts as the interactive visual board for each Grill round.
Chat remains the conversational orchestrator and event log.
Each round renders an interactive HTML page showing the decision tree, question cards with option buttons, and contextual recommendations.

### 2. Dual-Channel Input
Responses are accepted interchangeably through Lavish clicks or terminal chat.
Clicking option buttons in Lavish posts an answer back to the agent turn.
Replying with "yes" or typing custom answers in terminal chat advances the frontier identically.

### 3. Dynamic Visual Design Tree
Lavish renders a live dynamic Mermaid whiteboard graph of the decision tree.
Settled decisions are highlighted in green with their chosen rationale.
Active frontier questions are highlighted in blue or amber.
Unexplored downstream branches are dimmed until their prerequisites settle.
Clicking any diagram node scrolls to or highlights its corresponding question card.

### 4. Board Lifecycle and Focus-Aware Polling
A single persistent Lavish session URL is maintained throughout the interview.
Between rounds, the DOM and decision graph are updated in place without page reloads or tab churn.
HTTP long-polling in the Lavish browser client is strictly focus-aware.
Polling runs only while the browser tab has user focus (`document.visibilityState === 'visible'`).
When the tab is blurred or hidden, polling immediately suspends to avoid unnecessary background polling.
The agent uses a bounded wait so terminal chat remains responsive and is never locked out by browser state.

### 5. Embedded Evidence and Fact-Finding
The agent performs fact-finding lookups (filesystem, dependencies, configs) autonomously before presenting a frontier.
Each question card contains an expandable drawer displaying local file citations, diffs, and environment evidence.

### 6. Card UI and Quick Actions
Each card provides one-click pill buttons for options with the agent's recommended choice clearly highlighted.
Each card includes an optional text area for custom counter-proposals or caveats.
A sticky header action allows accepting all recommended choices with a single click.

### 7. State Persistence and Crash Safety
The full design tree, settled nodes, open frontier, and evidence log are saved to `data/grill/<slug>.json` after every round.
A cold agent restart or context compaction can resume the board immediately without losing answered branches.

### 8. Terminal Deliverables and Alignment Gate
When the frontier is empty, the session concludes with an explicit Alignment Summary presented in terminal chat.
No code is written and no tasks are dispatched until the captain explicitly confirms alignment in chat.
Once approved, the agent produces two deliverables:
- A committed Markdown specification following the ADR and RFC format.
- A persistent standalone HTML Lavish artifact preserving the full interactive decision log and whiteboard.
The agent automatically slices the ADR roadmap into discrete, context-sized Firstmate backlog tasks.

## Alternatives Considered

- Chat-only interview: Rejected because large decision trees and multi-choice trade-offs become difficult to track across long terminal scrolls.
- Continuous background polling: Rejected because never-ending background HTTP polling when the user is away or focused on terminal chat wastes cycles and network resources.
- Lavish-exclusive final gate: Rejected in favor of chat-only final confirmation to maintain direct captain oversight before task dispatch.
