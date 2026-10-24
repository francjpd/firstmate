# ADR & RFC: backlog-axi Interactive Task & Backlog Cockpit

**Status**: Approved & Settled  
**Date**: 2026-10-23  
**Authors**: Firstmate & Captain  
**Deciders**: Captain  

---

## 1. Context and Problem Statement
Firstmate manages durable tasks across multiple projects in `data/backlog.md` via `tasks-axi`. While `tasks-axi` provides a robust CLI interface (`tasks-axi list`, `start`, `done`, `rm`, `block`, `hold`), reviewing and triaging tasks in the terminal currently requires typing multiple commands or viewing static lists.

The captain requested an interactive, visual terminal experience:
> *"add a backlog-axi works the same way as bearings and it uses deck-axi to render. so if i say show me the backlog from home you should show me the list of tasks pending to do, doing and review, done. also the ability to cancel, move, etc."*

---

## 2. Settled Decisions (Grill Agreement)

### ADR-1: Standalone CLI + Deck Renderer Packaging
- **Decision**: Package as a dedicated binary `backlog-axi` that communicates with `tasks-axi` and delegates presentation to `deck-axi backlog`.
- **Rationale**: Reuses `deck-axi`'s alternate-screen rendering, Catppuccin/Aether theming, and Herdr multiplexer support while keeping `tasks-axi` domain logic isolated.

### ADR-2: Responsive 4-Column Kanban Layout
- **Decision**: Multi-column board grouping tasks by status:
  - **To Do** (`queued`)
  - **Doing** (`in_progress`)
  - **Review** (`review`)
  - **Done** (`done`)
- On compact terminals (< 120 columns), it dynamically collapses into switchable status tabs (`[1] To Do`, `[2] Doing`, `[3] Review`, `[4] Done`).

### ADR-3: Direct Card Hotkeys & Chat Mutations
- **Decision**: Fast keyboard hotkeys on the focused task card:
  - `[s]`: Start / Move to Doing (`tasks-axi start <id>`)
  - `[d]`: Mark Done (`tasks-axi done <id>`)
  - `[x]`: Cancel / Delete task (`tasks-axi rm <id>`)
  - `[h]`: Hold task (`tasks-axi hold <id>`)
  - `[m]`: Move column
  - `[Enter]`: View full task notes, dependencies, and PR details
  - Deliberation Chat: Right sidecar accepts natural language instructions (*"move task-1 to doing"*, *"cancel fm-deck-ingress"*).

### ADR-4: Synchronous `tasks-axi` CLI Execution
- **Decision**: Keystroke actions execute `tasks-axi` commands synchronously, updating `data/backlog.md` immediately with instant file watch re-rendering. No divergent in-memory drafts.

### ADR-5: Filter Toggle `[b]` for Blocked / Held Tasks
- **Decision**: Keep the primary 4-column workflow clean. Pressing `[b]` toggles between the active workflow and the Blocked/Held triage archive.

### ADR-6: Inline Task Creation `[a]` + Chat Addition
- **Decision**: Pressing `[a]` opens a quick prompt for title and slug, calling `tasks-axi add <slug> "<title>"`. Deliberation Chat acts as a conversational fallback.

---

## 3. Implementation Roadmap
- [x] **Grill Consensus & Architecture Settlement** (`backlog-axi.json`)
- [ ] **Task 1 (`deck-axi-backlog-view`)**: `<BacklogView>` component and `backlog` mode in `deck-axi`.
- [ ] **Task 2 (`backlog-axi-cli`)**: CLI binary in `.local/bin` wiring `tasks-axi` JSON and mutations.
- [ ] **Task 3 (`firstmate-backlog-trigger`)**: Natural language chat matcher (*"show me the backlog"*) in Firstmate.
