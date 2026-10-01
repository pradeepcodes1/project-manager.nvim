-- One spelling of "shell out and read the answer". A command that fails, is
-- not installed, or says nothing at all answers nil.
local M = {}

--- Trimmed stdout, or nil when the command failed or printed nothing.
---
--- vim.system raises rather than returning a code when the executable is
--- missing (uv_spawn ENOENT), so the capture is wrapped: a tool that is not
--- installed is the same answer as a tool that had nothing to say.
function M.capture(argv, opts)
	local ok, result = pcall(function()
		return vim.system(argv, vim.tbl_extend("force", { text = true }, opts or {})):wait()
	end)
	if not ok or result.code ~= 0 then
		return nil
	end

	local output = vim.trim(result.stdout or "")
	return output ~= "" and output or nil
end

--- A branch name to show. `--abbrev-ref` answers the literal "HEAD" on a
--- detached head, which is the honest label. A nil root answers nil rather
--- than running git against the cwd.
function M.git_branch(root)
	if type(root) ~= "string" or root == "" then
		return nil
	end

	return M.capture({ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" })
end

function M.has(name)
	return vim.fn.executable(name) == 1
end

--- Guard a launch on its executables, naming the first missing one. Returns
--- true when something is missing, so callers read as an early return.
function M.missing(what, ...)
	for _, name in ipairs({ ... }) do
		if not M.has(name) then
			vim.notify(("Cannot %s: %s is missing"):format(what, name), vim.log.levels.ERROR)
			return true
		end
	end

	return false
end

--- A GUI process this Neovim is only the launcher for, so it must outlive us.
---
--- pcall because jobstart raises E475 for a non-executable cmd[0] rather than
--- returning the -1 its docs promise, so `job <= 0` alone never sees the most
--- likely failure. Callers still front this with missing(), which names the
--- binary; this is what keeps the helper honest when one does not.
function M.detach(what, argv, opts)
	local ok, job = pcall(vim.fn.jobstart, argv, vim.tbl_extend("force", { detach = true }, opts or {}))
	if not ok or job <= 0 then
		vim.notify(("Failed to %s"):format(what), vim.log.levels.ERROR)
		return false
	end

	return true
end

return M
