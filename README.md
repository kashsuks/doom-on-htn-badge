# doom-on-htn-badge
Doom runs on the Hack the North 2026 badge

The badge's Lua app sandbox has no framebuffer, WAD loading, or audio
API, so a literal DOOM port isn't possible. `mini_doom.lua` is a
from-scratch first-person raycasting shooter built against the
documented badge APIs instead - see [setup.md](setup.md) for what it
does, its controls, and how to install it.
