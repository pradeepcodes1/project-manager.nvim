-- Which directory each feature should treat as "the project".
local M = {}

local clients = require("project-manager.lsp.clients")
local path = require("project-manager.util.path")
local session = require("project-manager.session")
local state = require("project-manager.state")

M.markers = {
	".git",
	"package.json",
	"pyproject.toml",
	"Cargo.toml",
	"go.mod",
	"pom.xml",
	"build.gradle",
	"Makefile",
}

--- The nearest marker root containing `file` (a file or a directory).
function M.find(file)
	file = path.normalize(file)
	if not file then
		return nil
	end

	local stat = vim.uv.fs_stat(file)
	local start = stat and stat.type == "directory" and file or vim.fs.dirname(file)
	return start and vim.fs.root(start, M.markers) or nil
end

--- The open project's root; otherwise the current buffer's marker root, and
--- failing that the cwd's.
function M.current()
	if state.is_open() then
		local root = session.root() or path.normalize(vim.g.project_root)
		if root then
			vim.g.project_root = root
			return root
		end
	end

	local file = path.buffer_file(0)
	return file and M.find(file) or M.find(vim.uv.cwd())
end

--- The workspace the servers attached to this buffer actually indexed: the
--- deepest LSP root or marker root that contains the file. Read back off the
--- clients that are about to answer the request, so a scope derived from this
--- can never point somewhere the results did not come from.
function M.buffer(bufnr)
	local file = path.normalize(path.buffer_file(bufnr))
	if not file then
		return nil
	end

	local candidates = clients.buffer_roots(bufnr or 0)
	local marker = path.clean(M.find(file))
	if marker then
		candidates[marker] = true
	end

	return path.longest_containing(candidates, file)
end

--- The root symbol and reference pickers scope to: the workspace whose server
--- is about to answer for this buffer, which is not always the open project.
---
--- Project mode wins only while the buffer actually belongs to the project.
--- Open a file from project B while project A is loaded and its client is
--- rooted at B (vim.lsp.start reuses a client only when the workspace folders
--- match), so every symbol comes back under B -- scoping those to A filters
--- the entire result set away and the picker looks empty.
---
--- nil means unscoped, the honest answer for a buffer belonging to no project.
function M.picker(bufnr)
	local buffer_root = M.buffer(bufnr)

	if state.is_open() then
		local root = M.current()
		-- Nested workspace folders resolve deeper than the project root, so a
		-- sub-package still scopes to the whole project rather than itself.
		if root and buffer_root and path.under(buffer_root, root) then
			return root
		end
	end

	return buffer_root
end

--- A real file in the current window, as opposed to a URI or a special buffer.
local function editable_file()
	return vim.bo.buftype == "" and path.buffer_file(0) or nil
end

--- Where file search looks. A directly opened file searches its containing
--- project when a marker identifies one, else its own directory; with no file,
--- the cwd unless that is / or $HOME.
function M.file_search()
	if state.is_open() then
		return M.current()
	end

	local file = path.normalize(editable_file())
	if file then
		return M.find(file) or vim.fs.dirname(file)
	end

	local cwd = path.normalize(vim.uv.cwd())
	if cwd == "/" or cwd == path.normalize(vim.uv.os_homedir()) then
		return nil
	end
	return cwd
end

--- Where project grep looks. Unlike file_search() this stays nil for an
--- unowned file instead of silently searching an arbitrary directory.
function M.project_search()
	if state.is_open() then
		return M.current()
	end

	local file = editable_file()
	return file and M.find(file) or nil
end

return M
