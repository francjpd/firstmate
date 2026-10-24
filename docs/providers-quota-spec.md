# Specification: Fleet Provider Telemetry, agy2 Quota & Routing Cockpit

## 1. Overview & Objectives

This specification defines the integration between:
1. **`quota-axi`**: Extended locally to support multi-subscription Antigravity telemetry (`agy` + `agy2`) under a unified family tree, with strict pre-push protection.
2. **`deck-axi`**: Providing an interactive `<ProviderView>` (Provider Cockpit) with active telemetry on the left and a Fleet Assignment Matrix on the right.
3. **Firstmate Dispatch**: Persisting assignments into `config/crew-dispatch.json` and `config/crew-harness`.

---

## 2. Upstream Push Guard & Local Branching

To guarantee zero accidental push to Kun Chen's upstream repository (`kunchenguid/quota-axi`), the cloned repository at `projects/quota-axi` (or `Projects/quota-axi`):
1. Runs on dedicated private branch `local/agy2-quota`.
2. Installs an executable `.git/hooks/pre-push`:
   ```bash
   #!/usr/bin/env bash
   # Fail-closed guard against pushing to upstream quota-axi
   remote="$1"
   url="$2"
   if [[ "$url" =~ kunchenguid/quota-axi ]]; then
     echo "ERROR: Refusing push to upstream quota-axi repository ($url)." >&2
     echo "Local modifications (agy2 adapter) must remain private." >&2
     exit 1
   fi
   exit 0
   ```
3. The built binary `dist/bin/quota-axi.js` is linked to `~/.local/bin/quota-axi` (which takes precedence over mise or system path).

---

## 3. `quota-axi` Provider Architecture: `agy2` & Family Hierarchy

### 3.1. Telemetry Extraction
- `agy` provider runs `agy -p "/quota" --output-format json` (or loopback discovery).
- `agy2` provider runs `agy2 -p "/quota" --output-format json`.
- Output parsing strips any banner prefix (such as `agy2: identity: andrease22@gmail.com (...)`) and extracts JSON from the line matching `{...}`.
- Model groups:
  - `gemini`: 5h limit (`gemini_5h`), weekly limit (`gemini_weekly`).
  - `claude_gpt`: 5h limit (`claude_gpt_5h`), weekly limit (`claude_gpt_weekly`).

### 3.2. Structured Representation
When rendered in TOON or JSON:
```
family[1]{name,activeSubs,overallHealth}:
  agy,2,healthy
subs[2]{family,subId,identity,scope,effectivePercentRemaining,resetsAt}:
  agy,agy,spirituz@gmail.com,gemini,63,"2026-10-23T22:01:41.000Z"
  agy,agy,spirituz@gmail.com,claude_gpt,100,"2026-10-24T02:39:13.000Z"
  agy,agy2,andrease22@gmail.com,gemini,63,"2026-10-23T22:01:41.000Z"
  agy,agy2,andrease22@gmail.com,claude_gpt,100,"2026-10-24T02:39:07.000Z"
```

---

## 4. `deck-axi` Provider Cockpit (`<ProviderView>`)

### 4.1. Visual Layout
Responsive split view:
```
┌─ Active Quota Telemetry ──────────────────────┐┌─ Fleet Assignment Matrix ────────────────────┐
│ ▼ agy (Antigravity)                  2 subs   ││ Secondmates: [ agy2 (andrease22) - gemini ]   │
│   ├─ agy (spirituz@gmail.com)                 ││ Crewmates:   [ agy2 (andrease22) - gemini ]   │
│   │    Gemini:    [████████░░░░] 63% (22m)    ││ Scouts:      [ Free Tier - gemini-flash ]     │
│   │    Claude/GPT:[████████████] 100%         ││                                               │
│   └─ agy2 (andrease22@gmail.com)              ││ ───────────────────────────────────────────── │
│        Gemini:    [████████░░░░] 63% (22m)    ││ [Enter/Space] Change Assignment               │
│        Claude/GPT:[████████████] 100%         ││ [1-3] Select Role                             │
│ ▼ opencode-go (1 sub)                         ││ Target: config/crew-dispatch.json             │
│   └─ opencode-go: [████░░░░░░░░] 26%          ││                                               │
└───────────────────────────────────────────────┘└───────────────────────────────────────────────┘
```

### 4.2. Filtering Rules
- Providers with no active credentials, 0 quota windows, or unmodeled status (e.g. `claude`, `grok` when not configured or absent) are **omitted entirely**.
- Only active, measurable providers (`agy`, `agy2`, `opencode-go`, etc.) are rendered.

### 4.3. Interactive Controls
- `[Tab]`: Switch focus between Left Pane (Telemetry tree) and Right Pane (Fleet Assignment).
- **Left Pane**:
  - `[j] / [k]` or `[↑] / [↓]`: Navigate provider rows.
  - `[Space] / [Enter]`: Toggle collapsible family node (`▼` / `▶`).
- **Right Pane**:
  - `[j] / [k]` or `[↑] / [↓]`: Navigate worker roles (`Secondmates`, `Crewmates`, `Scouts`).
  - `[Enter]`: Open Two-Tier Scope Picker:
    - Tier 1: Select Provider (`agy`, `agy2`, `opencode-go`) OR `Free Tier`.
    - Tier 2: Select Scope/Model:
      - For `agy`/`agy2`: `gemini-3.8-flash-high`, `gemini-3.8-flash-medium`, `claude-3-5-sonnet`, etc.
      - For `Free Tier`: `gemini-2.5-flash-free`, `gemini-2.5-pro-free`, etc.
  - On confirm, atomic rewrite of `config/crew-dispatch.json` and sync of `config/crew-harness`.

---

## 5. Firstmate Integration

1. `bin/fm-provider.sh`: Standalone launcher invoking `deck-axi provider` with automatic Herdr modal zoom.
2. Natural language triggers: `"show me providers"`, `"providers"`, `"fleet quota"`, `"provider cockpit"`.
