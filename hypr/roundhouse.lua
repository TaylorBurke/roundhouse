-- Drop-in window rules for roundhouse (Hyprland, Lua config).
-- Quickshell windows all share the app id "org.quickshell", so match on the title too.
-- Add to ~/.config/hypr/hyprland.lua:  dofile(os.getenv("HOME") .. "/Work/roundhouse/hypr/roundhouse.lua")
-- Remove the line to undo; nothing else is changed.

-- The all-sessions window: floats on every workspace.
o.window(
  { class = "^org\\.quickshell$", title = "^roundhouse$" },
  { float = true, size = { 360, 680 }, pin = true }
)

-- A window for one session (title "roundhouse: <name>"): not pinned, so it stays on the
-- workspace it was opened on, which is the terminal's.
o.window(
  { class = "^org\\.quickshell$", title = "^roundhouse: .*" },
  { float = true, size = { 360, 680 } }
)
