-- Project mode: whether this editor holds a project, and which root. Kept in
-- globals so statuslines and other plugins can read it without requiring us.
local M = {}

local path = require("project-manager.util.path")

function M.is_open()
	return vim.g.project_open == true
end

function M.set_open(value, root)
	vim.g.project_open = value == true
	if vim.g.project_open then
		vim.g.project_root = path.normalize(root) or vim.g.project_root or path.normalize(vim.uv.cwd())
	else
		vim.g.project_root = nil
	end
	require("project-manager.lsp.servers").project_changed(vim.g.project_root)
end

--- Wrap `callback` so it does nothing outside project mode.
function M.only(callback)
	return function(...)
		if not M.is_open() then
			return
		end
		return callback(...)
	end
end

return M
