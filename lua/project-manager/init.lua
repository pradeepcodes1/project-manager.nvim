local M = {}

local function create_commands()
	local function diagnostics(name)
		return function()
			require("project-manager.lsp.diagnostics")[name]()
		end
	end

	vim.api.nvim_create_user_command("Problems", diagnostics("show_workspace"), { desc = "Workspace diagnostics" })
	vim.api.nvim_create_user_command("ProblemsBuffer", diagnostics("show_buffer"), { desc = "Buffer diagnostics" })
	vim.api.nvim_create_user_command(
		"ProblemsRefresh",
		diagnostics("refresh_workspace"),
		{ desc = "Refresh workspace diagnostics" }
	)
end

function M.setup()
	require("project-manager.lsp.servers").setup()
	require("project-manager.state").set_open(false)
	create_commands()

	local group = vim.api.nvim_create_augroup("ProjectManager", { clear = true })
	-- The session pickers rely on this: they mark stale entries but offer no
	-- cleanup action of their own.
	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		once = true,
		desc = "Prune sessions whose project directory is gone",
		callback = function()
			require("project-manager.session").prune({ notify = false })
		end,
	})
	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		once = true,
		desc = "Open the project a picker launched this instance for",
		callback = function()
			require("project-manager.launch").restore_requested()
		end,
	})
end

return M
