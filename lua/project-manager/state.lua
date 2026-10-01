local M = {}

local cli = require("project-manager.util.cli")
local path_util = require("project-manager.util.path")

function M.is_open()
	return vim.g.project_open == true
end

function M.set_open(value, root)
	vim.g.project_open = value == true
	if vim.g.project_open then
		vim.g.project_root = path_util.normalize(root) or vim.g.project_root or path_util.normalize(vim.uv.cwd())
	else
		vim.g.project_root = nil
	end
	require("project-manager.servers").project_changed(vim.g.project_root)
end

function M.session_list()
	local sessions = require("auto-session")
	return require("auto-session.lib").get_session_list(sessions.get_root_dir())
end

function M.only(callback)
	return function(...)
		if not M.is_open() then
			return
		end
		return callback(...)
	end
end

--- The loaded session as auto-session names it ("<root>" or "<root>|<branch>"),
--- unescaped back out of the on-disk path in v:this_session.
function M.current_session_name()
	if vim.v.this_session == "" then
		return nil
	end

	local loaded, lib = pcall(require, "auto-session.lib")
	if not loaded then
		return nil
	end
	return lib.escaped_session_path_to_session_name(vim.v.this_session)
end

function M.restore_in_progress()
	local loaded, sessions = pcall(require, "auto-session")
	return (loaded and sessions.restore_in_progress) or vim.g.SessionLoad == 1
end

-- Session names are "<root>" or "<root>|<branch>", already unescaped and with
-- the legacy filename format folded in. Reading the list is what the session
-- picker does; rebuilding the on-disk name here instead meant depending on
-- auto-session's private escaping and its legacy fallback.
function M.find_session(root)
	root = path_util.normalize(root)
	if not root then
		return nil
	end

	local branch = cli.git_branch(root) or ""
	for _, entry in ipairs(M.session_list()) do
		local entry_root, entry_branch = path_util.parse_session_name(entry.session_name)
		if entry_root == root and entry_branch == branch then
			return entry
		end
	end

	return nil
end

function M.session_exists(root)
	return M.find_session(root) ~= nil
end

return M
