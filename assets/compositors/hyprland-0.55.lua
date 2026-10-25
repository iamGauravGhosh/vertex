-- Hyprland >= 0.55 (Lua configuration).
-- https://wiki.hypr.land/Configuring/Basics/Window-Rules/
-- Keep Vertex window.opacity below 1 to reveal compositor blur.
-- Enable blur and choose shadows/gaps in your existing compositor settings.
hl.window_rule({
    name = "vertex",
    match = { class = "^vertex$" },
    rounding = 12,
    border_size = 2,
})
-- Placement example for a separately configured floating instance:
-- hl.window_rule({ match = { class = "^vertex-floating$" }, float = true })

-- Optional GLOBAL effects: merge these values into your existing hl.config.
-- hl.config({
--     general = { gaps_in = 5, gaps_out = 10 },
--     decoration = {
--         blur = { enabled = true, size = 8, passes = 2 },
--         shadow = { enabled = true, range = 8, render_power = 3 },
--     },
-- })
