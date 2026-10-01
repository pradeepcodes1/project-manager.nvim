local M = {}

local project_paths = require("project-manager.paths")
local project_state = require("project-manager.state")
local path_util = require("project-manager.util.path")
local cli = require("project-manager.util.cli")
local info_namespace = vim.api.nvim_create_namespace("project_info")

--- The window holding a previous M.info() render, if one is still open.
local function info_window()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.b[vim.api.nvim_win_get_buf(win)].project_info then
			return win
		end
	end
end

--- Sized to the content it holds so long project paths remain readable.
local function fit_info_width(buf)
	local window = info_window()
	if not window then
		return
	end

	local width = 0
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end

	-- Keep project details above the editing buffer instead of permanently consuming a split.
	local max_width = math.floor(vim.o.columns * 0.8)
	local max_height = math.floor(vim.o.lines * 0.8)
	local panel_width = math.min(math.max(width + 2, 40), math.min(100, max_width))
	local panel_height = math.min(math.max(#lines + 2, 12), max_height)
	vim.api.nvim_win_set_config(window, {
		width = panel_width,
		height = panel_height,
		row = math.floor((vim.o.lines - panel_height) / 2),
		col = math.floor((vim.o.columns - panel_width) / 2),
	})
end

--- Color the stable labels and statuses without depending on a Treesitter parser
--- for this generated report.
local function highlight_info(buf)
	vim.api.nvim_buf_clear_namespace(buf, info_namespace, 0, -1)
	for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		local _, label_end = line:find("^%s*[%w ][%w ]*:%s*")
		if label_end then
			vim.hl.range(buf, info_namespace, "Title", { index - 1, 0 }, { index - 1, label_end })
		end
		for word, group in pairs({ yes = "DiagnosticOk", no = "DiagnosticWarn", none = "Comment" }) do
			local start = line:find("%f[%w]" .. word .. "%f[%W]")
			if start then
				vim.hl.range(buf, info_namespace, group, { index - 1, start - 1 }, { index - 1, start - 1 + #word })
			end
		end
	end
end

--- Every root this instance is holding, side by side. The scoping failures
--- this config has hit -- jdtls' cwd-named workspace, fS scoped to a root the
--- servers never indexed -- all look identical from the outside (an empty
--- picker) and all come apart the moment these are printed together.
---
--- A floating report rather than a notification: these are long paths read
--- against each other, and a toast that times out mid-comparison is the wrong
--- shape for that. Pressing the key again re-renders in place instead of
--- stacking a second panel.

function M.info()
	-- Gathered before the split exists. Every one of these answers for the
	-- current buffer, which the scratch pane is about to become.
	local root = project_paths.current_root()
	local lines = {
		("mode:        %s"):format(project_state.is_open() and "project" or "file only"),
		("root:        %s"):format(root or "none"),
		("cwd:         %s"):format(path_util.cwd() or "none"),
		("branch:      %s"):format(cli.git_branch(root) or "none"),
		("session:     %s"):format(project_state.current_session_name() or "not loaded"),
		("saved:       %s"):format(root and project_state.session_exists(root) and "yes" or "no"),
		("buffer root: %s"):format(project_paths.buffer_root() or "none"),
		("picker root: %s"):format(project_paths.picker_root() or "unscoped"),
	}

	vim.list_extend(lines, require("project-manager.servers").info(root))

	local clients = vim.lsp.get_clients({ bufnr = 0 })
	table.insert(lines, ("clients:     %s"):format(#clients == 0 and "none" or ""))
	for _, client in ipairs(clients) do
		table.insert(lines, ("  %s  %s"):format(client.name, client.root_dir or "no root"))
	end

	local window = info_window()
	local buf
	if window then
		vim.api.nvim_set_current_win(window)
		buf = vim.api.nvim_win_get_buf(window)
	else
		buf = vim.api.nvim_create_buf(false, true)
		vim.b[buf].project_info = true
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = "projectinfo"
		vim.api.nvim_buf_set_name(buf, "Project Info")
		-- `q` closes read-only panes here the way it closes a preview window;
		-- buffer-local, so macro recording is untouched everywhere else.
		vim.keymap.set("n", "q", "<C-w>c", { buffer = buf, desc = "Close project info" })

		-- A centered float preserves the current layout while making this report easy to dismiss.
		window = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			style = "minimal",
			border = "rounded",
			title = " Project Info ",
			title_pos = "center",
			width = 60,
			height = 20,
			row = 1,
			col = 1,
		})
		vim.wo.number = false
		vim.wo.relativenumber = false
		vim.wo.signcolumn = "no"
		vim.wo.wrap = false
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	highlight_info(buf)
	fit_info_width(buf)

	return true
end

return M
