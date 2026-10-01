local M = {}

local path_util = require("project-manager.util.path")
local project_state = require("project-manager.state")

M.root_markers = {
	".git",
	"package.json",
	"pyproject.toml",
	"Cargo.toml",
	"go.mod",
	"pom.xml",
	"build.gradle",
	"Makefile",
}

function M.session_root()
	local session_name = project_state.current_session_name()
	if not session_name then
		return nil
	end

	local root = path_util.normalize(session_name:match("^([^|]+)"))
	return root and vim.fn.isdirectory(root) == 1 and root or nil
end

function M.root(path)
	path = path_util.normalize(path)
	if not path then
		return nil
	end

	local stat = vim.uv.fs_stat(path)
	local start = stat and stat.type == "directory" and path or vim.fs.dirname(path)
	return start and vim.fs.root(start, M.root_markers) or nil
end

function M.current_root()
	if project_state.is_open() then
		local root = M.session_root() or path_util.normalize(vim.g.project_root)
		if root then
			vim.g.project_root = root
			return root
		end
	end

	local buffer_path = vim.api.nvim_buf_get_name(0)
	if buffer_path ~= "" and not buffer_path:match("^%w+://") then
		local root = M.root(buffer_path)
		if root then
			return root
		end
	end

	return M.root(vim.uv.cwd())
end

--- The workspace the servers attached to this buffer actually indexed: the
--- deepest LSP root or marker root that contains the file. Read back off the
--- clients that are about to answer the request, so a scope derived from this
--- can never point somewhere the results did not come from.
function M.buffer_root(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" or name:match("^%w+://") then
		return nil
	end

	local file = path_util.normalize(name)
	if not file then
		return nil
	end

	local candidates = path_util.lsp_roots(bufnr)
	local marker = path_util.clean(M.root(file))
	if marker then
		candidates[marker] = true
	end

	return path_util.longest_containing(candidates, file)
end

--- The root fS and gr scope to: the workspace whose server is about to answer
--- for this buffer, which is not always the open project.
---
--- Project mode wins only while the buffer actually belongs to the project.
--- Open a file from project B while project A is loaded and its client is
--- rooted at B (vim.lsp.start reuses a client only when the workspace folders
--- match), so every symbol comes back under B -- scoping those to A filters
--- the entire result set away and the picker looks empty. `fs` has no such
--- filter, which is why document symbols keep working when fS looks broken.
---
--- nil means unscoped, the honest answer for a buffer belonging to no project.
function M.picker_root(bufnr)
	local buffer_root = M.buffer_root(bufnr)

	if project_state.is_open() then
		local root = M.current_root()
		-- Nested workspace folders resolve deeper than the project root, so a
		-- sub-package still scopes to the whole project rather than itself.
		if root and buffer_root and path_util.under(buffer_root, root) then
			return root
		end
	end

	return buffer_root
end

function M.file_search_root()
	if project_state.is_open() then
		return M.current_root()
	end

	local buffer_path = vim.api.nvim_buf_get_name(0)
	if buffer_path ~= "" and not buffer_path:match("^%w+://") and vim.bo.buftype == "" then
		local path = path_util.normalize(buffer_path)
		-- A directly opened file should search its containing project when a marker identifies one.
		return M.root(path) or vim.fs.dirname(path)
	end

	local cwd = path_util.normalize(vim.uv.cwd())
	local home = path_util.normalize(vim.uv.os_homedir())
	if cwd == "/" or cwd == home then
		return nil
	end
	return cwd
end

function M.project_search_root()
	if project_state.is_open() then
		return M.current_root()
	end

	local buffer_path = vim.api.nvim_buf_get_name(0)
	if buffer_path ~= "" and not buffer_path:match("^%w+://") and vim.bo.buftype == "" then
		-- Grep stays unavailable for an unowned file instead of silently searching an arbitrary directory.
		return M.root(buffer_path)
	end

	return nil
end

return M
