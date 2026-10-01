local M = {}

local project_state = require("project-manager.state")
local path_util = require("project-manager.util.path")
-- An inaccessible directory is not evidence that its saved session should be
-- removed, so only paths that definitely no longer resolve count as stale.
function M.stale_session(item)
	local root = path_util.parse_session_name(item.session_name)
	if not root then
		return false
	end
	local stat, _, code = vim.uv.fs_stat(root)
	return (stat and stat.type ~= "directory") or code == "ENOENT" or code == "ENOTDIR"
end

function M.prune_stale_sessions(opts)
	opts = opts or {}
	local sessions = require("auto-session")
	local removed = 0
	for _, item in ipairs(project_state.session_list()) do
		if M.stale_session(item) and sessions.delete_session_file(item.path, item.display_name) then
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
