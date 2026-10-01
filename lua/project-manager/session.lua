-- auto-session glue: reading, matching and pruning saved project sessions.
--
-- Session names are "<root>" or "<root>|<branch>" (git_use_branch_name),
-- already unescaped and with the legacy filename format folded in. Reading the
-- list is what the session picker does; rebuilding the on-disk name here
-- instead would mean depending on auto-session's private escaping and its
-- legacy fallback.
local M = {}

local cli = require("project-manager.util.cli")
local path = require("project-manager.util.path")

--- The normalized root and the branch of a session name, "" when it carries none.
function M.parse_name(name)
	if type(name) ~= "string" then
		return nil, ""
	end

	local root, branch = name:match("^([^|]*)|?(.*)$")
	return path.normalize(root), branch
end

function M.list()
	local sessions = require("auto-session")
	return require("auto-session.lib").get_session_list(sessions.get_root_dir())
end

--- The loaded session's name, unescaped back out of the on-disk path in
--- v:this_session.
function M.current_name()
	if vim.v.this_session == "" then
		return nil
	end

	local loaded, lib = pcall(require, "auto-session.lib")
	if not loaded then
		return nil
	end
	return lib.escaped_session_path_to_session_name(vim.v.this_session)
end

--- The loaded session's root, while that directory still exists.
function M.root()
	local root = M.parse_name(M.current_name())
	return root and vim.fn.isdirectory(root) == 1 and root or nil
end

function M.restore_in_progress()
	local sessions = package.loaded["auto-session"]
	return vim.g.SessionLoad == 1 or (sessions ~= nil and sessions.restore_in_progress == true)
end

--- The session auto-session would restore for `root` on its current branch.
function M.find(root)
	root = path.normalize(root)
	if not root then
		return nil
	end

	local branch = cli.git_branch(root) or ""
	for _, entry in ipairs(M.list()) do
		local entry_root, entry_branch = M.parse_name(entry.session_name)
		if entry_root == root and entry_branch == branch then
			return entry
		end
	end

	return nil
end

function M.exists(root)
	return M.find(root) ~= nil
end

--- An inaccessible directory is not evidence that its saved session should be
--- removed, so only paths that definitely no longer resolve count as stale.
function M.is_stale(entry)
	local root = M.parse_name(entry.session_name)
	if not root then
		return false
	end

	local stat, _, code = vim.uv.fs_stat(root)
	return (stat and stat.type ~= "directory") or code == "ENOENT" or code == "ENOTDIR"
end

function M.prune(opts)
	opts = opts or {}
	local sessions = require("auto-session")
	local removed = 0
	for _, entry in ipairs(M.list()) do
		if M.is_stale(entry) and sessions.delete_session_file(entry.path, entry.display_name) then
			removed = removed + 1
		end
	end

	-- Startup cleanup should not announce the common zero-removal case.
	if opts.notify ~= false then
		vim.notify(("Pruned %d stale project session%s"):format(removed, removed == 1 and "" or "s"))
	end
	return removed
end

return M
