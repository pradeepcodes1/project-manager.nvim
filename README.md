# project-manager.nvim

Personal Neovim plugin, extracted from my dotfiles: project roots and sessions
(on top of auto-session), opt-in per-project language servers, and project-wide
LSP queries (workspace symbols and diagnostics across every server rooted in
the project, not only the current buffer's).

Requires auto-session, snacks.nvim, fff and yazi.nvim.

```lua
{ dir = "~/code/project-manager.nvim", lazy = false, dependencies = { ... } }
-- then, after lazy.setup:
require("project-manager").setup()
```
