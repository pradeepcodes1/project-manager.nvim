-- one spelling of "shell out and read the answer", for the handful of external
-- tools this config leans on: git, rg, chezmoi, onefetch, kitty, neovide.
--
-- Every caller here used to repeat the same four steps -- spawn, check the exit
-- code, trim the output, decide that empty means nothing -- and disagree about
-- one of them. This module makes that one decision: a command that fails, is
-- not installed, or says nothing at all answers nil.
local M = {}

--- vim.system raises rather than returning a code when the executable is
--- missing (uv_spawn ENOENT), so every capture is wrapped: a tool that is not
--- installed is the same answer as a tool that had nothing to say. Only
--- yank.lua guarded for this before, which is why a missing `chezmoi` used to
--- throw out of the explorer's BufEnter.
local function run(argv, opts)
	local ok, result = pcall(function()
		return vim.system(argv, vim.tbl_extend("force", { text = true }, opts or {})):wait()
	end)

	return ok and result or nil
end

--- Trimmed stdout, or nil when the command failed or printed nothing.
function M.capture(argv, opts)
	local result = run(argv, opts)
	if not result or result.code ~= 0 then
		return nil
	end

	local output = vim.trim(result.stdout or "")
	return output ~= "" and output or nil
end

--- stdout split on newlines, empty on failure. Deliberately not built on
--- capture(): these are log lines, and trimming the blob would eat leading
--- whitespace from the first one. A grep with no matches exits 1 and lands
--- here as {} rather than as an error.
function M.lines(argv, opts)
	local result = run(argv, opts)
	if not result or result.code ~= 0 then
		return {}
	end

	local output = (result.stdout or ""):gsub("\n$", "")
	return output == "" and {} or vim.split(output, "\n", { plain = true })
end

--- `git -C root ...`. nil root answers nil rather than running git against the
--- cwd, which is never what a caller holding a maybe-root wants.
function M.git(root, ...)
	if type(root) ~= "string" or root == "" then
		return nil
	end

	return M.capture(vim.list_extend({ "git", "-C", root }, { ... }))
end

--- A branch name to show. `--abbrev-ref` answers the literal "HEAD" on a
--- detached head, which is the honest label; yank.lua wants nil there instead
--- and asks for `symbolic-ref --quiet` directly.
function M.git_branch(root)
	return M.git(root, "rev-parse", "--abbrev-ref", "HEAD")
end

--- The worktree root, which is not the project root: from a subdirectory
--- onefetch reports the whole repository while tokei counts only the subtree.
function M.git_toplevel(root)
	return M.git(root, "rev-parse", "--show-toplevel")
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

--- The argv for a detached Kitty OS window at `root`, running the trailing
--- command or a plain shell when none is given.
function M.kitty_argv(root, title, ...)
	return vim.list_extend({ "kitty", "--detach", "--directory", root, "--title", title }, { ... })
end

--- Terminal escapes, so a tool's colored output lands as text. NO_COLOR is set
--- for these too; this is the belt to that pair of braces.
function M.strip_ansi(text)
	return (text:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("\27%][^\7]*\7", ""))
end

--- Environment for a tool whose output is about to be read rather than shown.
M.no_color = { NO_COLOR = "1" }

--- Every file rg will admit to, NUL-separated, with the directories no server
--- wants to index pruned. Not `--files-with-matches`: the point is the file
--- list itself, which project_lsp then classifies by filetype.
function M.rg_files()
	local command = { "rg", "--files", "--hidden", "--null" }
	for _, directory in ipairs({
		".git",
		"node_modules",
		".venv",
		"venv",
		"__pycache__",
		"vendor",
		"target",
		"build",
		"dist",
		".next",
		".gradle",
	}) do
		vim.list_extend(command, { "--glob", "!**/" .. directory .. "/**" })
	end

	return command
end

return M
