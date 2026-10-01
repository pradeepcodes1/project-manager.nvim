-- Pull workspace diagnostics on demand, since servers only publish for open buffers.
local M = {}

local methods = vim.lsp.protocol.Methods or {}
local workspace_diagnostic_method = methods.workspace_diagnostic or "workspace/diagnostic"

-- Every server rooted in the project, not only the foreground buffer's: a Go
-- buffer must still pull pyright's diagnostics. Never every client in the
-- editor either, or a server rooted in another project does a full workspace
-- pull for results the picker then filters away. No root, no project: only
-- the buffer's own servers.
local function workspace_clients(root)
	if not root then
		return vim.lsp.get_clients({ bufnr = 0, method = workspace_diagnostic_method })
	end

	return require("project-manager.util.path").root_clients(root, workspace_diagnostic_method)
end

-- Diagnostics for files nobody has opened exist only after a workspace pull.
-- Without this the project view shows the open buffers and calls it a project.
function M.refresh_workspace(root)
	root = root or require("project-manager.paths").current_root()
	local clients = workspace_clients(root)
	for _, client in ipairs(clients) do
		vim.lsp.buf.workspace_diagnostics({ client_id = client.id })
	end

	return #clients > 0
end

function M.show_workspace()
	local root = require("project-manager.paths").current_root()
	M.refresh_workspace(root)
	Snacks.picker.diagnostics({ filter = { cwd = root } })
end

function M.show_buffer()
	Snacks.picker.diagnostics_buffer()
end

vim.api.nvim_create_user_command("Problems", M.show_workspace, {
	desc = "Workspace diagnostics",
})

vim.api.nvim_create_user_command("ProblemsBuffer", M.show_buffer, {
	desc = "Buffer diagnostics",
})

vim.api.nvim_create_user_command("ProblemsRefresh", function()
	M.refresh_workspace()
end, {
	desc = "Refresh workspace diagnostics",
})

return M
