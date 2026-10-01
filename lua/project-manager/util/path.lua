-- One spelling of the path questions every module here ends up asking.
local M = {}

--- Absolute, symlink-resolved, forward-slashed. nil for anything unusable,
--- so callers can guard once instead of checking types.
function M.normalize(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local absolute = vim.fn.fnamemodify(path, ":p")
	return vim.fs.normalize(vim.uv.fs_realpath(absolute) or absolute)
end

--- vim.fs.normalize only, for paths already known to be absolute and real.
--- Cheap enough for per-item checks, where normalize()'s realpath is not.
function M.clean(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	return vim.fs.normalize(path)
end

--- Is `path` the root itself or inside it? The trailing slash matters:
--- without it "/tmp/foobar" counts as inside "/tmp/foo".
function M.under(path, root)
	path, root = M.clean(path), M.clean(root)
	if not path or not root then
		return false
	end

	return path == root or vim.startswith(path, root .. "/")
end

--- The deepest of `roots` (a set) that contains `path`. Language servers
--- report nested workspace folders, and the innermost one is the useful answer.
function M.longest_containing(roots, path)
	local best
	for root in pairs(roots) do
		if M.under(path, root) and (not best or #root > #best) then
			best = root
		end
	end

	return best
end

--- The buffer's name when it names a file on disk: not empty, and not a
--- `scheme://` URI such as jdt://, oil:// or term://.
function M.buffer_file(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr or 0)
	if name == "" or name:match("^%w+://") then
		return nil
	end

	return name
end

function M.cwd()
	return M.clean(vim.uv.cwd() or vim.fn.getcwd())
end

return M
