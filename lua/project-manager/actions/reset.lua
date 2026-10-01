local M = {}
local project_paths = require("project-manager.paths")

--- Collapse the layout down to one window. Floats go first, since `:only`
--- leaves them behind; then the other tab pages, then the other windows. The
--- panels with teardown of their own (explorer, aerial, dapui, neotest) are
--- closed by the caller before this runs, so they are not merely hidden.
local function close_windows()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	-- `:only` keeps whichever window is current, so pressing this from a scratch
	-- pane -- the info split, a leftover panel -- would make that pane the one
	-- survivor. Hand it a real file window to keep instead.
	if vim.bo.buftype ~= "" then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
				vim.api.nvim_set_current_win(win)
				break
			end
		end
	end

	-- Silent because both are informational when there is nothing to close
	-- ("Already only one window"), and this runs off a key press.
	vim.cmd("silent! tabonly")
	vim.cmd("silent! only")
end

--- Back to what a freshly restored project looks like: one window, no buffers,
--- the file picker open. The session on disk is left alone, so this is a clean
--- slate to work from and not a discard. Modified file buffers stay -- nothing
--- here is worth losing an edit over. Unmodified files outside the project are
--- cleared too, since a reset must not leak buffers opened from another project.
function M.reset()
	local root = project_paths.current_root()
	if not root then
		return false
	end

	-- Tear down diff ownership before collapsing tabs so reset cannot leave a phantom diff view.
	local diffs = package.loaded["codediff.ui.lifecycle"]
	if diffs then
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if diffs.get_session(tab) and not diffs.close(tab) then
				return false
			end
		end
	end

	close_windows()

	local kept = 0
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		-- Restrict the sweep to editable file buffers so plugin terminals and
		-- other special buffers can run their own teardown instead of being killed.
		if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
			if vim.bo[buf].modified then
				kept = kept + 1
			else
				pcall(vim.api.nvim_buf_delete, buf, {})
			end
		end
	end

	if kept > 0 then
		vim.notify(("Kept %d modified buffer%s"):format(kept, kept == 1 and "" or "s"), vim.log.levels.WARN)
	end

	-- Layout cleanup must retain project identity even when it removes every file buffer.
	vim.cmd({ cmd = "cd", args = { root }, mods = { noautocmd = true } })
	require("project-manager.state").set_open(true, root)
	-- Seed the root before fff's native index initializes, as the keymaps do.
	require("fff.conf").get().base_path = root
	require("fff").find_files({
		cwd = root,
		preview = { enabled = false },
		layout = {
			width = function(columns)
				return math.min(0.8, 90 / columns)
			end,
		},
	})
	return true
end

return M
