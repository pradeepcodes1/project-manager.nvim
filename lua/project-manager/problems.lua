-- Pull workspace diagnostics on demand, since servers only publish for open buffers.
local M = {}

local methods = vim.lsp.protocol.Methods or {}
local workspace_diagnostic_method = methods.workspace_diagnostic or "workspace/diagnostic"

local function workspace_clients()
	local clients = vim.lsp.get_clients({ bufnr = 0, method = workspace_diagnostic_method })
	if #clients > 0 then
		return clients
	end

	return vim.lsp.get_clients({ method = workspace_diagnostic_method })
end

-- Diagnostics for files nobody has opened exist only after a workspace pull.
-- Without this the project view shows the open buffers and calls it a project.
function M.refresh_workspace()
	local clients = workspace_clients()
	for _, client in ipairs(clients) do
		vim.lsp.buf.workspace_diagnostics({ client_id = client.id })
	end

	return #clients > 0
end

function M.show_workspace()
	local project_paths = require("project-manager.paths")
	M.refresh_workspace()
	Snacks.picker.diagnostics({ filter = { cwd = project_paths.current_root() } })
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
