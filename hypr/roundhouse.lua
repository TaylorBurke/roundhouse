-- Drop-in window rule for roundhouse (Hyprland, Lua config).
-- Quickshell windows all share the app id "org.quickshell", so match on the title too.
-- Add to ~/.config/hypr/hyprland.lua:  dofile(os.getenv("HOME") .. "/Work/roundhouse/hypr/roundhouse.lua")
-- Remove the line to undo; nothing else is changed.
o.window(
  { class = "^org\\.quickshell$", title = "^roundhouse$" },
  { float = true, size = { 360, 680 }, pin = true }
)
