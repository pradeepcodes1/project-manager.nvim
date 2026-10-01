-- A floating report of every root this instance is holding.
local M = {}

local cli = require("project-manager.util.cli")
local path = require("project-manager.util.path")
local root = require("project-manager.root")
local session = require("project-manager.session")
local state = require("project-manager.state")

local namespace = vim.api.nvim_create_namespace("project_info")

--- The window holding a previous M.show() render, if one is still open.
local function find_window()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.b[vim.api.nvim_win_get_buf(win)].project_info then
			return win
		end
	end
end

--- Gathered before the float exists. Every one of these answers for the
--- current buffer, which the report is about to become.
local function report()
	local project_root = root.current()
	local lines = {
		("mode:        %s"):format(state.is_open() and "project" or "file only"),
		("root:        %s"):format(project_root or "none"),
		("cwd:         %s"):format(path.cwd() or "none"),
		("branch:      %s"):format(cli.git_branch(project_root) or "none"),
		("session:     %s"):format(session.current_name() or "not loaded"),
		("saved:       %s"):format(project_root and session.exists(project_root) and "yes" or "no"),
		("buffer root: %s"):format(root.buffer() or "none"),
		("picker root: %s"):format(root.picker() or "unscoped"),
	}

	vim.list_extend(lines, require("project-manager.lsp.servers").info(project_root))

	local clients = vim.lsp.get_clients({ bufnr = 0 })
	table.insert(lines, ("clients:     %s"):format(#clients == 0 and "none" or ""))
	for _, client in ipairs(clients) do
		table.insert(lines, ("  %s  %s"):format(client.name, client.root_dir or "no root"))
	end

	return lines
end

--- A centered float preserves the current layout while making this report easy to dismiss.
local function open_window()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.b[buf].project_info = true
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "projectinfo"
	vim.api.nvim_buf_set_name(buf, "Project Info")
	-- `q` closes read-only panes here the way it closes a preview window;
	-- buffer-local, so macro recording is untouched everywhere else.
	vim.keymap.set("n", "q", "<C-w>c", { buffer = buf, desc = "Close project info" })

	local window = vim.api.nvim_open_win(buf, true, {
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
	vim.wo[window].signcolumn = "no"
	vim.wo[window].wrap = false
	return window
end

--- Sized to the content it holds so long project paths remain readable.
local function fit(window, lines)
	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end

	local panel_width = math.min(math.max(width + 2, 40), math.min(100, math.floor(vim.o.columns * 0.8)))
	local panel_height = math.min(math.max(#lines + 2, 12), math.floor(vim.o.lines * 0.8))
	vim.api.nvim_win_set_config(window, {
		relative = "editor",
		width = panel_width,
		height = panel_height,
		row = math.floor((vim.o.lines - panel_height) / 2),
		col = math.floor((vim.o.columns - panel_width) / 2),
	})
end

--- Color the stable labels and statuses without depending on a Treesitter parser
--- for this generated report.
local function highlight(buf, lines)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	for index, line in ipairs(lines) do
		local _, label_end = line:find("^%s*[%w ][%w ]*:%s*")
		if label_end then
			vim.hl.range(buf, namespace, "Title", { index - 1, 0 }, { index - 1, label_end })
		end
		for word, group in pairs({ yes = "DiagnosticOk", no = "DiagnosticWarn", none = "Comment" }) do
			local start = line:find("%f[%w]" .. word .. "%f[%W]")
			if start then
				vim.hl.range(buf, namespace, group, { index - 1, start - 1 }, { index - 1, start - 1 + #word })
			end
		end
	end
end

--- Every root this instance is holding, side by side. The scoping failures
--- this has to explain -- a server's cwd-named workspace, workspace symbols
--- scoped to a root the servers never indexed -- all look identical from the
--- outside (an empty picker) and all come apart the moment these are printed
--- together.
---
--- A floating report rather than a notification: these are long paths read
--- against each other, and a toast that times out mid-comparison is the wrong
--- shape for that. Showing it again re-renders in place instead of stacking a
--- second panel.
function M.show()
	local lines = report()

	local window = find_window()
	if window then
		vim.api.nvim_set_current_win(window)
	else
		window = open_window()
	end

	local buf = vim.api.nvim_win_get_buf(window)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	highlight(buf, lines)
	fit(window, lines)

	return true
end

return M
