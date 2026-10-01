-- Pull workspace diagnostics on demand, since servers only publish for open buffers.
local M = {}

local method = "workspace/diagnostic"

-- Every server rooted in the project, not only the foreground buffer's: a Go
-- buffer must still pull pyright's diagnostics. Never every client in the
-- editor either, or a server rooted in another project does a full workspace
-- pull for results the picker then filters away. No root, no project: only
-- the buffer's own servers.
local function workspace_clients(root)
	if not root then
		return vim.lsp.get_clients({ bufnr = 0, method = method })
	end

	return require("project-manager.lsp.clients").for_root(root, method)
end

-- Diagnostics for files nobody has opened exist only after a workspace pull.
-- Without this the project view shows the open buffers and calls it a project.
function M.refresh_workspace(root)
	root = root or require("project-manager.root").current()
	local clients = workspace_clients(root)
	for _, client in ipairs(clients) do
		vim.lsp.buf.workspace_diagnostics({ client_id = client.id })
	end

	return #clients > 0
end

function M.show_workspace()
	local root = require("project-manager.root").current()
	M.refresh_workspace(root)
	Snacks.picker.diagnostics({ filter = { cwd = root } })
end

function M.show_buffer()
	Snacks.picker.diagnostics_buffer()
end

return M
