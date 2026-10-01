-- Workspace symbol requests belong to the open project, not the foreground buffer.
local M = {}
local project_paths = require("project-manager.paths")
local project_pickers = require("project-manager.actions.pickers")
local project_state = require("project-manager.state")
local path_util = require("project-manager.util.path")

local prose_extensions = {
	adoc = true,
	asciidoc = true,
	markdown = true,
	md = true,
	mdown = true,
	mdx = true,
	mkd = true,
	mkdn = true,
	norg = true,
	org = true,
	rmd = true,
	rst = true,
	txt = true,
}

function M.include_file(file)
	if type(file) ~= "string" or file == "" then
		return true
	end
	local extension = file:match("%.([^./]+)$")
	return extension == nil or not prose_extensions[extension:lower()]
end

function M.clients(root)
	local clients = {}
	for _, client in ipairs(vim.lsp.get_clients()) do
		local belongs = false
		for path in pairs(path_util.client_roots(client)) do
			belongs = belongs or path_util.under(path, root) or path_util.under(root, path)
		end
		if
			belongs
			and client.initialized
			and not client:is_stopped()
			and client:supports_method("workspace/symbol")
		then
			clients[#clients + 1] = client
		end
	end
	table.sort(clients, function(a, b)
		return a.name == b.name and a.id < b.id or a.name < b.name
	end)
	return clients
end

-- Main-thread request coordinator. Every query owns its requests and deadline;
-- cancelling a picker never cancels another feature's LSP work.
--
-- Symbols arriving without a location range are dropped, not resolved. LSP 3.17
-- lets a server omit ranges and answer workspaceSymbol/resolve for them, but only
-- when the client declares workspace.symbol.resolveSupport -- which this config
-- deliberately does not. Resolving here could only be eager, one round trip per
-- symbol (4700+ for the empty query fS opens with, measured against lua_ls on
-- this config), to spare the server a bulk computation it performs anyway; and
-- the whole cascade would sit under the deadline below, so it would time out
-- rather than merely run slow. Snacks needs a range to preview and jump, so a
-- rangeless symbol is unusable regardless.
function M.request(clients, query, emit, done, timeout_ms)
	local requests, errors = {}, {}
	-- Starts at 1 so a synchronous reply mid-dispatch cannot complete the batch
	-- before every client has been sent; the loop drops that sentinel.
	local pending, stopped = 1, false
	local timer
	local function stop(cancel)
		if stopped then
			return
		end
		stopped = true
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		if cancel then
			for _, request in ipairs(requests) do
				if not request.finished and request.id then
					pcall(request.client.cancel_request, request.client, request.id)
				end
			end
		end
	end
	local function complete()
		if not stopped and pending == 0 then
			stop(false)
			done(errors)
		end
	end
	local function settle(request, err, symbols)
		if stopped or request.finished then
			return
		end
		request.finished = true
		if err then
			errors[request.client.name] = err.message or tostring(err)
		elseif symbols then
			local ready = {}
			for _, symbol in ipairs(symbols) do
				if symbol.location and symbol.location.range then
					ready[#ready + 1] = symbol
				end
			end
			local ok, failure = pcall(emit, request.client, ready)
			if not ok then
				errors[request.client.name] = tostring(failure)
			end
		end
		pending = pending - 1
		complete()
	end
	for _, client in ipairs(clients) do
		local request = { client = client, finished = false }
		requests[#requests + 1] = request
		pending = pending + 1
		local function handler(err, result)
			settle(request, err, result)
		end
		local ok, accepted, id = pcall(client.request, client, "workspace/symbol", { query = query }, handler)
		request.id = id
		if not ok or not accepted then
			settle(request, { message = ok and "request rejected" or tostring(accepted) })
		end
	end
	pending = pending - 1
	complete()
	if not stopped then
		timer = vim.defer_fn(function()
			for _, request in ipairs(requests) do
				if not request.finished then
					errors[request.client.name] = "timed out"
				end
			end
			stop(true)
			done(errors)
		end, timeout_ms or 8000)
	end
	return function()
		stop(true)
	end
end

function M.finder(root)
	return function(_, ctx)
		local clients = M.clients(root)
		local names = vim.tbl_map(function(client)
			return client.name
		end, clients)
		ctx.picker.title = "Project symbols · " .. (#names > 0 and table.concat(names, ", ") or "no active servers")
		local lsp = require("snacks.picker.source.lsp")
		local bufmap = lsp.bufmap()
		return function(cb)
			local async = ctx.async
			local queue, seen = {}, {}
			local finished, errors, cancel = false, {}, nil
			async:on(
				"abort",
				vim.schedule_wrap(function()
					if cancel then
						cancel()
					end
				end)
			)
			async:schedule(function()
				if async:aborted() then
					return
				end
				cancel = M.request(clients, ctx.filter.search or "", function(client, symbols)
					local items = lsp.results_to_items(client, symbols, { text_with_file = true })
					for _, item in ipairs(items) do
						if M.include_file(item.file) then
							item.buf = bufmap[item.file]
							item.tree = false
							queue[#queue + 1] = item
						end
					end
					async:resume()
				end, function(failures)
					finished, errors = true, failures
					async:resume()
				end)
			end)
			while true do
				local batch = queue
				queue = {}
				for _, item in ipairs(batch) do
					local key = table.concat({ item.file, item.name, item.kind, item.pos[1], item.pos[2] }, "\0")
					if not seen[key] then
						seen[key] = true
						cb(item)
					end
				end
				if finished and #queue == 0 then
					break
				end
				if #queue == 0 then
					async:suspend()
				end
			end
			if next(errors) then
				async:schedule(function()
					local failed = vim.tbl_keys(errors)
					table.sort(failed)
					ctx.picker.title = "Project symbols · incomplete: " .. table.concat(failed, ", ")
					ctx.picker:update_titles()
				end)
			end
		end
	end
end

function M.open()
	-- Preserve file-only mode's buffer-local server selection and scope.
	if not project_state.is_open() then
		return Snacks.picker.lsp_workspace_symbols(project_pickers.picker_scope(project_paths.picker_root()))
	end
	local root = project_paths.current_root()
	if not root then
		vim.notify("No open project root", vim.log.levels.WARN)
		return
	end
	local opts = project_pickers.picker_scope(root)
	opts.finder = M.finder(root)
	-- This Snacks version defers picker teardown but resets finder.task before
	-- its aborted coroutine necessarily unwinds. Finish that unwind while the
	-- matcher still exists, so closing during a request cannot touch a nil UI.
	opts.on_close = function(picker)
		local task = picker.finder.task
		task:abort()
		task:step()
	end
	-- Across languages, show every symbol kind instead of applying the active
	-- buffer's language-specific kind filter to unrelated servers' results.
	opts.filter = { default = true }
	return Snacks.picker.lsp_workspace_symbols(opts)
end

return M
