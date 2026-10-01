# project-manager.nvim

Personal Neovim plugin, extracted from my dotfiles: project roots and sessions
(on top of auto-session), opt-in per-project language servers, and project-wide
LSP queries (workspace symbols and diagnostics across every server rooted in
the project, not only the current buffer's).

Requires Neovim 0.12+ (`vim.lsp.get_configs`, `vim.lsp.buf.workspace_diagnostics`),
auto-session, snacks.nvim, fff, yazi.nvim and ripgrep.

```lua
{ dir = "~/code/project-manager.nvim", lazy = false, dependencies = { ... } }
-- then, after lazy.setup:
require("project-manager").setup()
```

`setup()` registers `:Problems`, `:ProblemsBuffer` and `:ProblemsRefresh`, prunes
sessions whose directory is gone, and opens the project a picker launched this
instance for. Everything else is called from keymaps:

| Module                       | Use                                                                     |
| ---------------------------- | ----------------------------------------------------------------------- |
| `project-manager.state`      | `is_open()`, `set_open(open, root)`, `only(fn)`: project mode           |
| `project-manager.root`       | `current()`, `buffer()`, `picker()`, `file_search()`, `project_search()` |
| `project-manager.session`    | auto-session glue: `root()`, `find(root)`, `prune()`                    |
| `project-manager.picker`     | `projects()`, `delete_sessions()`, `open_directory()`, `scope(root)`    |
| `project-manager.launch`     | `open_session(name)`, `open_root(root)`, `new_window()`, `terminal()`   |
| `project-manager.reset`      | `reset()`: one window, no buffers, file picker open                     |
| `project-manager.info`       | `show()`: every root this instance holds, side by side                  |
| `project-manager.lsp.*`      | `servers.toggle()`, `symbols.open()`, `diagnostics.show_workspace()`    |
