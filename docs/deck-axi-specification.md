# deck-axi Architecture Decision Record and Specification

This document defines the architecture, user experience, and technical specification for `deck-axi`, Firstmate's terminal-native visual bridge and interactive deliberation cockpit built with React Ink and dynamic Omarchy Aether theming.

## Context

Lavish provided browser-based HTML visual review boards, but opening an external browser introduces window management friction, headless browser / DevTools port conflicts, and breaks terminal-centric workflows.
`deck-axi` replaces Lavish completely by delivering an instantaneous (<50ms startup), keyboard-driven cockpit directly within the terminal's alternate screen buffer.

## Settled Decisions

### 1. Alternate Screen Execution and Scrollback Discipline
`deck-axi` executes exclusively within the terminal's alternate screen buffer (`\x1b[?1049h`).
It occupies a clean, full-screen interactive card workspace without polluting terminal scrollback during navigation.
Upon completion or exit, it restores the main buffer (`\x1b[?1049l`) and prints an 8-to-10 line summary receipt card summarizing settled decisions and pointing to generated artifacts.

### 2. Multi-Mode Visual Bridge (`deck-axi <mode>`)
`deck-axi` hosts multiple visual modes under a single, unified TUI:
- **`deck-axi grill <session.json>`**: The interactive decision tree, Unicode/ASCII whiteboard, and frontier question cards.
- **`deck-axi bearings`**: Replaces `/bearings lavish` with fleet telemetry, active crewmates, open PR health, and backlog horizon.
- **`deck-axi review <diff|pr>`**: Visual code diff viewer, structured review findings, and audit receipts.
- **`deck-axi view <spec.json>`**: Generic declarative schema for arbitrary agent-driven boards, prompts, and forms.

Modes are accessible via CLI arguments or switched live inside the TUI with hotkeys `1` (Grill), `2` (Bearings), and `3` (Review).

### 3. Integrated Deliberation Chat Sidecar
On wide terminals ($\ge 100$ columns), `deck-axi` renders a responsive 2-column cockpit:
- **Left Column (55% width)**: The active View Deck (Grill tree & cards, Bearings fleet tables, or Review diffs).
- **Right Column (45% width)**: The live Deliberation Chat stream and `<ChatInput>`.
- Pressing **`Tab`** seamlessly toggles keyboard focus between Left Deck navigation and Right Chat input.
- On narrow displays ($< 100$ columns), the layout collapses into a single column with hotkey toggling (`Ctrl+T`).

### 4. Reactive IPC Architecture
`deck-axi` communicates with Firstmate and background agents via reactive file watching:
- State file (`data/deck/<slug>.json`): Watched via `fs.watch`. Updating the file re-renders rounds or fleet telemetry in place without redrawing the entire screen.
- Chat log (`data/deck/<slug>.chat.jsonl`): An append-only newline-delimited stream. Firstmate appends prompts or responses, which instantly stream into `<ChatStream>`. Typing in `<ChatInput>` appends user replies to the file.

### 5. Internal Primitive Design System (`src/components/ui/`)
Modeled after `termcn.dev` and `@inkjs/ui`—zero bloated runtime dependencies:
- `<Card>`: Container with Unicode box-drawing borders (`┌─┐│└─┘`), title bar, badge, and footer.
- `<Tabs>`: Top navigation bar with active indicators.
- `<Badge>`: Color-coded status pills (`✓ Settled`, `⚡ Active`, `✗ Failed`).
- `<ChatStream>`: Scrollable bubble stream with role indicators (`[Captain]`, `[Firstmate]`, `[Agent]`).
- `<ChatInput>`: Interactive text input with history recall.
- `<Table>`: Columnar data grid with auto-width calculation and Yoga flexbox.
- `<DiagramBox>`: Theme-aware Unicode/ASCII architecture and flowchart renderer.

### 6. Dynamic Theming with Omarchy Aether
`deck-axi` dynamically reads `~/.config/aether/theme/colors.toml` on startup.
It extracts colors generated from the user's active Omarchy desktop wallpaper:
- `accent` for selection highlights and card borders.
- `green` for settled nodes and successful checks.
- `yellow` for frontier questions and warnings.
- `muted` for dimmed lines and inactive text.
- `background` and `foreground` for base contrast.
Falls back gracefully to Catppuccin and ANSI-16 on low-color terminals.

### 7. Packaging and Distribution
- Packaged as an independent AXI CLI in repository `francjpd/deck-axi`.
- Globally symlinked to `deck-axi` and alias `deck`.
- Firstmate skills invoke `deck-axi` or `deck` directly for terminal visualization.
