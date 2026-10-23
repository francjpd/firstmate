# Deck-AXI Component Patterns & TUI Design System
**Status**: Adopted & Active Specification  
**Inspiration**: `termcn.dev`, `@inkjs/ui`, LazyGit, K9s, Textual, Omarchy Aether

---

## 1. Executive Summary & Scout Findings

`deck-axi` replaces the browser-based Lavish visual board with a lightning-fast (<50ms startup), terminal-native React Ink cockpit. 

A survey of modern terminal design systems revealed that ad-hoc TUI tools fail because they duplicate layout calculations, hard-code borders and colors, and lack clear focus management. In contrast, registries like **`termcn.dev`** and **`@inkjs/ui`** demonstrate that a copy-paste primitive architecture—mirroring `shadcn/ui` for the terminal—provides maximum extensibility, zero runtime bloat, and minimal token consumption when building new views.

`deck-axi` establishes an internal, zero-dependency `src/components/ui/` primitive library dynamically styled by the user's active Omarchy Aether wallpaper palette (`~/.config/aether/theme/colors.toml`).

---

## 2. Core UI Primitive Catalog (`src/components/ui/`)

All views in `deck-axi` (Bearings, Grill, Code Review, and generic View Specs) are composed from eight battle-tested primitives:

### 2.1 `<Card>` (`Card.tsx`)
Container box with standardized border styles, title bar, content body, and status footer.
- **Borders**: Clean Unicode (`┌─┐│└─┘`) or rounded box characters (`╭─╮│╰─╯`).
- **Props**:
  ```typescript
  interface CardProps {
    title?: string;
    subtitle?: string;
    badge?: string;
    badgeVariant?: 'success' | 'warning' | 'error' | 'info' | 'accent';
    focused?: boolean;
    borderColor?: string;
    padding?: number;
    children: React.ReactNode;
    footer?: React.ReactNode;
  }
  ```

### 2.2 `<Tabs>` & `<TabList>` (`Tabs.tsx`)
Top-level mode navigation across views (`[Bearings]  [Grill]  [Review]  [Specs]`).
- **Props**:
  ```typescript
  interface TabsProps {
    tabs: Array<{ id: string; label: string; shortcut?: string; badge?: string }>;
    activeTab: string;
    onSelectTab: (id: string) => void;
  }
  ```
- **Keybindings**: `1-4` for direct tab jump; `[` and `]` or `Shift+Left/Right` for sequential navigation.

### 2.3 `<Badge>` (`Badge.tsx`)
Status pills and category tags.
- **Variants**:
  - `success`: Green foreground, dark green/black surface (e.g., `✓ Settled`, `PR Open`).
  - `warning`: Yellow foreground (e.g., `⚡ Active Frontier`, `Blocked`).
  - `error`: Red foreground (e.g., `✗ Failed`, `Rejected`).
  - `info`: Blue / cyan foreground (e.g., `ℹ Pending`, `Round 2`).
  - `outline`: Muted border with text color.

### 2.4 `<ChatStream>` (`ChatStream.tsx`)
Scrollable message stream for real-time agent/captain deliberation.
- **Features**:
  - Auto-scrolls to the bottom on new tokens.
  - Formatted message bubbles with role headers: `[Captain]`, `[Firstmate]`, `[System]`.
  - Timestamps and token-stream indicators (`...`).
  - Up/Down scrolling when the chat pane is focused.

### 2.5 `<ChatInput>` (`ChatInput.tsx`)
Interactive text input bar powered by `ink-text-input`.
- **Features**:
  - Live cursor rendering (`█` block or `_` underline).
  - History recall: `Up` / `Down` arrows cycle through previous inputs.
  - Multi-line awareness or single-line expansion.
  - Hotkeys: `Enter` sends message, `Esc` blurs input, `Ctrl+U` clears line.

### 2.6 `<Tree>` (`Tree.tsx`)
Hierarchical tree explorer for decision graphs, project files, and backlog horizons.
- **Connectors**: Standard Unicode tree branching (`├── `, `└── `, `│   `).
- **State Indicators**:
  - `[✓]` Settled node / committed decision.
  - `[●]` Active frontier / currently focused branch.
  - `[○]` Unvisited future branch.
- **Navigation**: `j` / `k` (or `Down` / `Up`) moves selection; `Space` or `Enter` expands/collapses.

### 2.7 `<Table>` (`Table.tsx`)
Columnar data grid for fleet metrics, task statuses, and pull request audits.
- **Features**:
  - Auto-calculated column widths with Yoga flexbox.
  - Header dividers (`├──┼──┤`) with aligned text (left, right, center).
  - Row selection highlighting with cursor pointer (`►`).

### 2.8 `<DiagramBox>` (`DiagramBox.tsx`)
Theme-aware Unicode/ASCII whiteboard renderer.
- **Features**:
  - Renders flowcharts and architecture diagrams natively without browser or WebGL.
  - Directional connectors (`──►`, `▲`, `▼`, `◄──`).
  - Supports node pills with status colors matching Omarchy Aether.

---

## 3. Screen Layout & Responsive Cockpit Grid

`deck-axi` executes in the alternate screen buffer (`\x1b[?1049h`), clearing completely on exit (`\x1b[?1049l`).

### 3.1 Dual-Column Responsive Grid ($\ge 100$ columns)
```
┌─ [deck-axi] [1:Bearings] [2:Grill] [3:Review] ────────── [? Help] [q:Exit] ──┐
│                                            │                                 │
│  LEFT PANE (View Deck: 50%)                │  RIGHT PANE (Chat Sidecar: 50%) │
│  Focused: [Tab] toggles focus              │  Focused: [Tab] toggles focus   │
│                                            │                                 │
│  <Card title="Decision Frontier">          │  <Card title="Deliberation">    │
│    <Tree nodes={nodes} />                  │    <ChatStream messages={...} />│
│    <DiagramBox chart={flowchart} />        │    <ChatInput onSend={...} />   │
│  </Card>                                   │  </Card>                        │
│                                            │                                 │
├────────────────────────────────────────────┴─────────────────────────────────┤
│ [NORMAL]  Round 2/3  •  Tree: 3 settled, 2 frontier  •  Theme: Aether Dark   │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Single-Column Auto-Collapse ($< 100$ columns)
On narrow screens or floating terminal windows:
- The screen renders either the **View Deck** or the **Chat Sidecar** at 100% width.
- `Ctrl+T` or `c` toggles between View and Chat views instantly.
- A status badge (`[View Active]` or `[Chat Active]`) appears in the bottom status line.

---

## 4. Keyboard Navigation & Interaction Model

Following LazyGit and K9s conventions:

| Key | Context | Action |
| :--- | :--- | :--- |
| `Tab` | Global | Toggle focus between Left Deck and Right Chat |
| `1` – `4` | Left Deck | Jump directly to Tab (1: Bearings, 2: Grill, 3: Review, 4: Specs) |
| `j` / `k` (or `↓` / `↑`) | Left Deck | Navigate tree nodes / question cards / table rows |
| `y` | Grill Mode | Accept all recommended answers across frontier |
| `1` – `4` (or `a` – `d`) | Grill Question | Toggle option checkboxes on focused card |
| `Enter` | Chat Input | Submit message to agent IPC channel |
| `Ctrl+T` | Global | Toggle Chat sidecar collapse / full-width expansion |
| `?` | Global | Open modal keybinding cheat sheet |
| `q` | Left Deck (Normal) | Save state and exit alternate screen buffer |

---

## 5. Reactive IPC Architecture (`data/deck/<slug>.chat.jsonl`)

To allow Firstmate and autonomous agents to stream deliberation prompts while the user types in the TUI:

1. **Session File (`data/deck/<slug>.json`)**:
   - Holds durable state: view mode, decision tree, settled choices, fleet status.
   - Watched with `fs.watch`; whenever an external agent or script updates the file, `deck-axi` updates the React tree in place without redrawing the entire screen.

2. **Chat Stream Log (`data/deck/<slug>.chat.jsonl`)**:
   - Append-only newline-delimited JSON stream:
     ```json
     {"id":"m1","role":"agent","text":"Which session invalidation strategy should we choose?","ts":1792735100}
     {"id":"m2","role":"captain","text":"BroadcastChannel with storage event fallback","ts":1792735140}
     {"id":"m3","role":"agent","text":"Excellent. That survives cross-origin frames cleanly.","ts":1792735145}
     ```
   - Agent streams token deltas or full messages by appending lines to this file.
   - `deck-axi` watches the file and scrolls new messages into `<ChatStream>`.

---

## 6. Token & Performance Benefits

1. **Zero Reinvention**: Firstmate does not generate custom SVG/HTML for each question or board. It emits a compact JSON structure that `deck-axi` maps directly to its native primitives.
2. **Context Efficiency**: Instead of writing 2,000 tokens of HTML/CSS output per turn, agent tools emit compact ~150-token JSON diffs.
3. **Execution Speed**: Renders in <50ms with zero Chromium processes, headless browser harnesses, or DevTools port conflicts.
