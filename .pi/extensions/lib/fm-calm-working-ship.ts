// Firstmate's Calm-only animated working presentation for Pi.
//
// Calm replaces Pi's stock working row with a tiny SSHHIP-derived boat while one
// logical agent run is active. The sprite geometry, bounce track, two animation
// cadences, palette classes, and freeze/resume state are owned by the harness-neutral
// ./fm-calm-working-ship-sprite.ts (a tracked symlink into the Claude Code Calm mod,
// which both harnesses share); this module owns only Pi's rendering of those frames
// as standard ANSI escapes and the temporary TUI widget. `.pi/extensions/fm-calm.ts`
// owns when the presentation is installed and removed, and stays the sole caller of
// setWorkingVisible(). docs/calm.md owns the captain-facing contract.
//
// Continuity: one extension-owned animation instance survives hide/show within the same
// Pi process and Calm extension lifetime. Disposing the widget freezes column,
// direction, water phase, and tick cadence without advancing them for hidden wall
// time. The next working period resumes from that exact logical state. A fresh session
// or new extension lifetime calls reset() and starts at the normal initial position.
// State is never a module-level or process-global singleton.
//
// Verified against Pi 0.81.1 declarations and the Pi 0.82.0 CLI, which expose
// ExtensionUIContext.setWidget() with a component factory, per-widget dispose(), and
// TUI.requestRender(). Pi renders a widget through Component.render(width), so this
// module recomputes its track from that width on every frame instead of caching a
// terminal size that a resize would invalidate. A resize while the boat is hidden is
// applied on the first resumed frame through the same clamp path.
import type { Component, TUI } from "@earendil-works/pi-tui";
import {
  CALM_WORKING_SHIP_TICK_MS,
  CALM_WORKING_SHIP_TICKS_PER_MOVE,
  createCalmWorkingShipSprite,
  type CalmWorkingShipColor,
  type CalmWorkingShipRun,
  type CalmWorkingShipSprite,
} from "./fm-calm-working-ship-sprite.ts";

export { CALM_WORKING_SHIP_TICK_MS, CALM_WORKING_SHIP_TICKS_PER_MOVE };

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
// Water is a single blue so the swell reads through glyph height alone; the boat is a
// single yellow so its sail halves, mast, and hull never split into mismatched colors.
const ANSI_FOREGROUND: Record<Exclude<CalmWorkingShipColor, "plain">, string> = {
  water: "\u001b[34m",
  boat: "\u001b[33m",
};
// Restores the default foreground so color never bleeds into padding or later frames.
const RESET = "\u001b[39m";

// The working-row widget slot is deliberately shared with the standalone Pi Calm
// extension, which installs its boat under the same "calm-working-ship" key. Pi
// replaces widgets under one key, so a session that loads both Calms renders a
// single boat and a session loading either alone is unchanged. Rename the slot
// in both implementations together, or dual-install sessions duplicate the boat.
export const CALM_WORKING_SHIP_WIDGET_KEY = "calm-working-ship";

export type CalmWorkingShipAnimation = Omit<CalmWorkingShipSprite, "frame"> & {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
};

/** One run painted as its standard ANSI escape, closed with a default-foreground reset. */
function paintRun(run: CalmWorkingShipRun): string {
  if (run.color === "plain") return run.text;
  return `${ANSI_FOREGROUND[run.color]}${run.text}${RESET}`;
}

export function createCalmWorkingShipAnimation(): CalmWorkingShipAnimation {
  const sprite = createCalmWorkingShipSprite();
  return {
    position: sprite.position,
    direction: sprite.direction,
    waterPhase: sprite.waterPhase,
    restoreLastRendered: sprite.restoreLastRendered,
    reset: sprite.reset,
    clampToWidth: sprite.clampToWidth,
    tick: sprite.tick,
    render(width: number): string[] {
      return sprite.frame(width).map((row) => row.map(paintRun).join(""));
    },
  };
}

/**
 * The Model-delay indicator drawn beside the boat while that mode is on.
 * U+29D7 BLACK HOURGLASS is a sandglass and, unlike the wide U+231B HOURGLASS, is one
 * terminal column, so it never breaks the working row's width math. One glyph plus a
 * one-cell separator, kept in the same working widget rather than a parallel one.
 * docs/model-delay.md owns the captain-facing contract.
 */
export const MODEL_DELAY_SANDGLASS = "⧗";
const MODEL_DELAY_SANDGLASS_SEGMENT = ` ${MODEL_DELAY_SANDGLASS}`;
const MODEL_DELAY_SANDGLASS_COLUMNS = 2;

export type CalmWorkingWidgetOptions = {
  /** Draw the boat; defaults to true so a lone caller is unchanged. */
  ship?: () => boolean;
  /** Draw the Model-delay sandglass beside the boat; defaults to false. */
  sandglass?: () => boolean;
};

/**
 * Build the temporary Calm working widget bound to one caller-owned animation.
 * Pi disposes the previous component before installing a replacement under the same
 * key and when it clears extension widgets, so the single scheduler driving both
 * cadences cannot outlive the widget or duplicate. Disposing freezes the shared
 * animation in place; the next widget bound to the same animation resumes without
 * applying hidden wall time.
 * The optional `ship` and `sandglass` providers are read on every frame, so a live
 * preference toggle only needs a repaint, never a widget reinstall.
 */
export function createCalmWorkingShipWidget(
  tui: TUI,
  animation: CalmWorkingShipAnimation = createCalmWorkingShipAnimation(),
  options: CalmWorkingWidgetOptions = {},
): Component & { dispose(): void } {
  let disposed = false;
  const timer = setInterval(() => {
    if (disposed) return;
    animation.tick();
    tui.requestRender();
  }, CALM_WORKING_SHIP_TICK_MS);
  // The animation must never keep Pi's process alive on its own.
  timer.unref?.();

  const renderRows = (width: number): string[] => {
    const showShip = options.ship ? options.ship() : true;
    const showSandglass = options.sandglass ? options.sandglass() : false;
    if (!showSandglass) return showShip ? animation.render(width) : [];
    if (width <= 0) return [];
    if (!showShip) return [`${MODEL_DELAY_SANDGLASS}${' '.repeat(Math.max(0, width - 1))}`];
    // Reserve the sandglass columns on the boat row so the indicator sits beside the
    // boat instead of wrapping. The sail row is deliberately shorter than the boat's
    // water row, exactly as the lone boat draws it; only the boat row carries width.
    const shipWidth = Math.max(1, width - MODEL_DELAY_SANDGLASS_COLUMNS);
    const rows = animation.render(shipWidth);
    if (rows.length === 0) return [];
    return [
      ...rows.slice(0, -1),
      rows[rows.length - 1] + MODEL_DELAY_SANDGLASS_SEGMENT,
    ];
  };

  return {
    render: (width) => (disposed ? [] : renderRows(width)),
    // Every frame is rebuilt from fixed standard ANSI codes, so there is no cache.
    invalidate: () => {},
    dispose: () => {
      if (disposed) return;
      disposed = true;
      clearInterval(timer);
      animation.restoreLastRendered();
    },
  };
}
