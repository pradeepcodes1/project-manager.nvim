-- one spelling of the path questions every module here ends up asking.
local M = {}

local function parent(path)
	return path ~= "" and vim.fs.dirname(path) or nil
end

local function default_homebrew_prefix()
	if vim.env.HOMEBREW_PREFIX and vim.env.HOMEBREW_PREFIX ~= "" then
		return vim.env.HOMEBREW_PREFIX
	end

	local brew = vim.fn.exepath("brew")
	if brew ~= "" then
		return parent(parent(brew))
	end

	if vim.uv.os_uname().sysname == "Darwin" then
		return vim.uv.os_uname().machine == "arm64" and "/opt/homebrew" or "/usr/local"
	end
	return "/home/linuxbrew/.linuxbrew"
end

-- Machine-dependent roots live here with the path constructors that consume them.
M.homebrew_prefix = default_homebrew_prefix()
M.applications_dir = vim.env.APPLICATIONS_DIR or "/Applications"

function M.homebrew(path)
	return vim.fs.joinpath(M.homebrew_prefix, path)
end

function M.application(name, path)
	local bundle = name:sub(-4) == ".app" and name or (name .. ".app")
	return vim.fs.joinpath(M.applications_dir, bundle, path or "")
end

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
--- Cheap enough to call per Neo-tree row, where normalize() is not.
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

--- The deepest of `roots` that contains `path`. Language servers report
--- nested workspace folders, and the innermost one is the useful answer.
function M.longest_containing(roots, path)
	local best
	for root in pairs(roots) do
		if M.under(path, root) and (not best or #root > #best) then
			best = root
		end
	end

	return best
end

--- Every root one client claims, as a set. Clients report these three ways and
--- disagree about which they populate.
---
--- WorkspaceFolder.uri is the location; .name is only a display label, which the
--- spec never requires to be a path. Reading .name first would replace a real
--- root with something like "Backend Services" -- inert, since no absolute file
--- can sit under it, but the real root then goes missing from the set entirely
--- and buffer_root() falls back to a marker root or to nil. nil scopes nothing,
--- so grr would quietly widen to every dependency it was meant to exclude.
---
--- Each root is offered in both spellings, symlink-resolved and not, because the
--- callers compare against differently-normalized paths: project.lua realpaths
--- the buffer's file while ui/explorer only cleans it. Only a spelling
--- that actually contains the file can win longest_containing(), so the extra
--- entries are inert wherever they do not apply.
function M.client_roots(client)
	local roots = {}

	local function add(root)
		local cleaned = M.clean(root)
		if cleaned then
			roots[cleaned] = true
		end

		local real = M.normalize(root)
		if real then
			roots[real] = true
		end
	end

	add(client.root_dir)
	if client.config then
		add(client.config.root_dir)
	end

	local folders = client.workspace_folders or (client.config and client.config.workspace_folders)
	for _, folder in ipairs(type(folders) == "table" and folders or {}) do
		local ok, fname = pcall(vim.uri_to_fname, folder.uri or "")
		add(ok and fname or folder.name)
	end

	return roots
end

--- Every root the servers attached to `bufnr` claim, as a set.
function M.lsp_roots(bufnr)
	local roots = {}

	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		for root in pairs(M.client_roots(client)) do
			roots[root] = true
		end
	end

	return roots
end

function M.cwd()
	return M.clean(vim.uv.cwd() or vim.fn.getcwd())
end

return M
