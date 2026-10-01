-- Which roots a language server claims, and which servers belong to a project.
local M = {}

local path = require("project-manager.util.path")

--- Every root one client claims, as a set. Clients report these three ways and
--- disagree about which they populate.
---
--- WorkspaceFolder.uri is the location; .name is only a display label, which the
--- spec never requires to be a path. Reading .name first would replace a real
--- root with something like "Backend Services" -- inert, since no absolute file
--- can sit under it, but the real root then goes missing from the set entirely
--- and root.buffer() falls back to a marker root or to nil. nil scopes nothing,
--- so a reference picker would quietly widen to every dependency it was meant
--- to exclude.
---
--- Each root is offered in both spellings, symlink-resolved and not, because
--- callers compare against differently-normalized paths. Only a spelling that
--- actually contains the file can win longest_containing(), so the extra
--- entries are inert wherever they do not apply.
function M.roots(client)
	local roots = {}

	local function add(root)
		local cleaned = path.clean(root)
		if cleaned then
			roots[cleaned] = true
		end

		local real = path.normalize(root)
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
function M.buffer_roots(bufnr)
	local roots = {}

	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		for root in pairs(M.roots(client)) do
			roots[root] = true
		end
	end

	return roots
end

--- The live clients supporting `method` that belong to the project at `root`:
--- rooted inside it, or at a parent that contains it. Not the foreground
--- buffer's clients, and never every client in the editor. Sorted by name so
--- results and titles come out in a stable order.
function M.for_root(root, method)
	local clients = {}
	for _, client in ipairs(vim.lsp.get_clients({ method = method })) do
		local belongs = false
		for client_root in pairs(M.roots(client)) do
			if path.under(client_root, root) or path.under(root, client_root) then
				belongs = true
				break
			end
		end
		if belongs and client.initialized and not client:is_stopped() then
			clients[#clients + 1] = client
		end
	end

	table.sort(clients, function(a, b)
		return a.name == b.name and a.id < b.id or a.name < b.name
	end)
	return clients
end

return M
