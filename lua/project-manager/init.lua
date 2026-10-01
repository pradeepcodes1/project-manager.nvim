local M = {}

local project_state = require("project-manager.state")

function M.setup()
	require("project-manager.servers").setup()
	project_state.set_open(false)

	vim.api.nvim_create_autocmd("VimEnter", {
		desc = "Restore a project explicitly launched by the project picker",
		once = true,
		callback = function()
			-- Create directory-selected projects in their own process without changing the launcher's workspace.
			local directory = vim.env.NVIM_PROJECT_DIRECTORY
			vim.env.NVIM_PROJECT_DIRECTORY = nil
			if directory and directory ~= "" then
				vim.env.NVIM_PROJECT_SESSION = nil
				vim.schedule(function()
					local root = require("project-manager.util.path").normalize(directory)
					if not root or vim.fn.isdirectory(root) ~= 1 then
						vim.notify("Project directory does not exist", vim.log.levels.ERROR)
						return
					end
					vim.cmd({ cmd = "cd", args = { root }, mods = { noautocmd = true } })
					local sessions = require("auto-session")
					if project_state.session_exists(root) then
						sessions.restore_session(nil, { show_message = false })
					else
						vim.cmd.enew()
						project_state.set_open(true, root)
						sessions.save_session(nil, { show_message = false })
					end
				end)
				return
			end
			-- Only picker-launched instances receive this marker, so ordinary files stay file-only.
			local requested_session = vim.env.NVIM_PROJECT_SESSION
			if requested_session and requested_session ~= "" then
				vim.env.NVIM_PROJECT_SESSION = nil
				project_state.set_open(true, requested_session:match("^([^|]+)"))
				vim.schedule(function()
					if
						not require("auto-session").restore_session(
							requested_session,
							{ is_startup_autorestore = true, show_message = false }
						)
					then
						project_state.set_open(false)
					end
				end)
			end
		end,
	})
end

return M
