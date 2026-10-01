-- Opt-in LSP startup, persisted per canonical project root (not per branch).
--
-- When a project with startup enabled opens, rg lists its files, each
-- (server, directory, filetype) gets one representative file, and every
-- enabled server whose root resolves inside the project is started there
-- without attaching it to a visible buffer.
local M = {}

local cli = require("project-manager.util.cli")
local path = require("project-manager.util.path")
local session = require("project-manager.session")

-- Java is excluded: its lazily loaded plugin is never started from here.
local excluded = { jdtls = true }

local SCAN_TIMEOUT_MS = 15000
local ROOT_TIMEOUT_MS = 5000
local CLASSIFY_BATCH = 100
local MAX_PENDING = 8

--- Every file rg will admit to, NUL-separated, with the directories no server
--- wants to index pruned.
local scan_command = { "rg", "--files", "--hidden", "--null" }
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
	vim.list_extend(scan_command, { "--glob", "!**/" .. directory .. "/**" })
end

-- The discovery run for the open project, if any.
local active
-- Hidden buffers kept loaded so tsserver keeps their projects open, until the
-- user enters one.
local seeds = {}

--- Run `callback` with every autocommand suppressed, so probe and seed
--- buffers stay invisible to file plugins.
local function quiet(callback)
	local events = vim.o.eventignore
	vim.o.eventignore = "all"
	local ok, value = pcall(callback)
	vim.o.eventignore = events
	if not ok then
		error(value, 0)
	end
	return value
end

local function delete_buffer(buf)
	quiet(function()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)
end

local function metadata_file(root)
	return vim.fn.stdpath("state") .. "/project-lsp/" .. vim.fn.sha256(root) .. ".json"
end

--- Whether startup is enabled for `root`, plus an error for unreadable metadata.
local function is_enabled(root)
	root = path.normalize(root)
	if not root then
		return false
	end
	local file = metadata_file(root)
	if vim.fn.filereadable(file) == 0 then
		return false
	end
	local ok, data = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
	end)
	if not ok or type(data) ~= "table" or data.root ~= root or type(data.enabled) ~= "boolean" then
		return false, "Invalid project LSP metadata: " .. file
	end
	return data.enabled
end

--- Written atomically, and never over metadata that failed to parse.
local function set_enabled(root, enabled)
	root = assert(path.normalize(root), "Project root required")
	local _, err = is_enabled(root)
	if err then
		return false, err
	end
	local file = metadata_file(root)
	local temp = file .. "." .. vim.uv.os_getpid() .. ".tmp"
	local ok, failure = pcall(function()
		vim.fn.mkdir(vim.fs.dirname(file), "p")
		assert(
			vim.fn.writefile({ vim.json.encode({ root = root, enabled = enabled == true, version = 1 }) }, temp) == 0
		)
		assert(vim.uv.fs_rename(temp, file))
	end)
	if not ok then
		vim.fn.delete(temp)
		return false, tostring(failure)
	end
	return true
end

--- Enabled configs grouped by filetype, each group in name order.
local function configs_by_filetype()
	local configs = vim.tbl_filter(function(config)
		return not excluded[config.name] and not vim.tbl_contains(config.filetypes or {}, "java")
	end, vim.lsp.get_configs({ enabled = true }))
	table.sort(configs, function(a, b)
		return a.name < b.name
	end)

	local by_ft = {}
	for _, config in ipairs(configs) do
		for _, ft in ipairs(config.filetypes or {}) do
			by_ft[ft] = by_ft[ft] or {}
			table.insert(by_ft[ft], config)
		end
	end
	return by_ft
end

local function alive(run)
	return active == run and not run.cancelled
end

--- A hidden buffer for `file` that root callbacks can inspect. Only buffers
--- created here are counted in run.probes, so only those are ever deleted.
local function probe(run, file, ft)
	local buf = vim.fn.bufnr(file)
	if buf < 0 then
		buf = quiet(function()
			return vim.fn.bufadd(file)
		end)
		run.probes[buf] = 0
		quiet(function()
			vim.bo[buf].filetype = ft
		end)
	end
	if run.probes[buf] then
		run.probes[buf] = run.probes[buf] + 1
	end
	return buf
end

local function release(run, buf, force)
	if not run.probes[buf] then
		return
	end
	run.probes[buf] = run.probes[buf] - 1
	if not force and run.probes[buf] > 0 then
		return
	end
	run.probes[buf] = nil
	if not seeds[buf] and vim.api.nvim_buf_is_valid(buf) then
		delete_buffer(buf)
	end
end

local function cancel()
	local run = active
	if not run then
		return
	end
	run.cancelled = true
	if run.scan then
		pcall(run.scan.kill, run.scan, 15)
	end
	for buf in pairs(run.probes) do
		release(run, buf, true)
	end
	-- Seeds outlive their probe so tsserver keeps each project open, but not
	-- the project. Still in `seeds` means never entered; a modified or shown
	-- one holds a workspace edit or a view the user has not finished with.
	for buf in pairs(run.seeds) do
		if
			seeds[buf]
			and vim.api.nvim_buf_is_valid(buf)
			and not vim.bo[buf].modified
			and #vim.fn.win_findbuf(buf) == 0
		then
			seeds[buf] = nil
			delete_buffer(buf)
		end
	end
	active = nil
end

--- tsserver needs an open document per tsconfig/jsconfig project, even when
--- several of those share one lockfile/server root in a monorepo.
local function seed_typescript(run, entry, file, ft)
	local seed_root = vim.fs.root(file, { "tsconfig.json", "jsconfig.json" }) or entry.root
	entry.seed_roots = entry.seed_roots or {}
	if entry.seed_roots[seed_root] then
		return
	end
	local buf = probe(run, file, ft)
	local needs_events = not vim.api.nvim_buf_is_loaded(buf)
	quiet(function()
		vim.fn.bufload(buf)
		vim.bo[buf].filetype = ft
	end)
	local ok, attached = pcall(vim.lsp.buf_attach_client, buf, entry.id)
	if not ok or not attached then
		entry.error = "could not initialize TypeScript project"
		release(run, buf)
		return
	end
	entry.seed_roots[seed_root] = true
	if needs_events then
		seeds[buf] = true
		-- Only a buffer probe() created is ours to delete on cancel; an
		-- unloaded one the session listed stays in the buffer list.
		if run.probes[buf] then
			run.seeds[buf] = true
		end
		run.probes[buf] = nil
	end
end

--- Start `config` at `root` once per run, unattached.
local function start(run, config, root, file, ft)
	root = path.normalize(root)
	-- A broad fallback (e.g. HOME) must not start unrelated workspaces.
	if not alive(run) or not root or not path.under(root, run.root) then
		return
	end
	local key = config.name .. "\0" .. root
	local entry = run.entries[key]
	if not entry then
		entry = { name = config.name, root = root }
		run.entries[key] = entry
		local resolved = vim.deepcopy(config)
		resolved.root_dir = root
		local ok, id =
			pcall(vim.lsp.start, resolved, { attach = false, reuse_client = config.reuse_client, silent = true })
		entry.id = ok and id or nil
		entry.error = not entry.id and (ok and "failed to start (check :LspLog)" or tostring(id)) or nil
	end
	if entry.id and config.name == "ts_ls" then
		seed_typescript(run, entry, file, ft)
	end
end

--- Find the root `job.config` would use for `job.file` and start it there,
--- then call `done` exactly once.
local function resolve(run, job, done)
	local config = job.config
	if type(config.cmd) == "table" and not cli.has(config.cmd[1]) then
		run.skipped[config.name] = "missing executable: " .. config.cmd[1]
		done()
		return
	end
	if type(config.root_dir) ~= "function" then
		local root = config.root_dir or (config.root_markers and vim.fs.root(job.file, config.root_markers))
		start(run, config, root, job.file, job.ft)
		done()
		return
	end

	local buf = probe(run, job.file, job.ft)
	local finished = false
	local timer
	local function finish(root, err)
		if finished then
			return
		end
		finished = true
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		if alive(run) then
			if err then
				run.skipped[config.name] = err
			else
				local ok, failure = pcall(start, run, config, root, job.file, job.ft)
				if not ok then
					run.skipped[config.name] = tostring(failure)
				end
			end
		end
		release(run, buf)
		done()
	end

	local ok, err = pcall(config.root_dir, buf, function(root)
		vim.schedule(function()
			finish(root)
		end)
	end)
	if not ok then
		finish(nil, tostring(err))
	else
		-- Root callbacks may deliberately decline a file (e.g. ts_ls for Deno)
		-- or resolve asynchronously (Cargo metadata). Do not keep probes forever.
		timer = vim.defer_fn(function()
			finish(nil)
		end, ROOT_TIMEOUT_MS)
	end
end

--- Run resolve() over every job with at most MAX_PENDING root callbacks in
--- flight, yielding to the event loop between batches.
local function resolve_all(run, jobs)
	run.status = "resolving workspaces"
	local next_job, pending, scheduled = 1, 0, false
	local pump

	local function schedule_pump()
		if scheduled or not alive(run) then
			return
		end
		scheduled = true
		vim.defer_fn(function()
			scheduled = false
			pump()
		end, 1)
	end

	local function job_done()
		pending = pending - 1
		schedule_pump()
	end

	pump = function()
		if not alive(run) then
			return
		end
		local batch = 0
		while pending < MAX_PENDING and batch < MAX_PENDING and jobs[next_job] do
			batch = batch + 1
			local job = jobs[next_job]
			next_job, pending = next_job + 1, pending + 1
			local ok, err = pcall(resolve, run, job, job_done)
			if not ok then
				run.skipped[job.config.name] = tostring(err)
				pending = pending - 1
			end
		end
		if not jobs[next_job] and pending == 0 then
			run.status = "discovery complete"
		elseif jobs[next_job] and pending < MAX_PENDING then
			schedule_pump()
		end
	end

	pump()
end

--- One job per (server, directory, filetype): a single file is enough for a
--- root callback to place its directory. Classified CLASSIFY_BATCH files per
--- tick so a large tree never blocks the UI.
local function classify(run, files, by_ft, callback)
	local index, jobs, seen = 1, {}, {}

	local function step()
		if not alive(run) then
			return
		end
		for _ = 1, CLASSIFY_BATCH do
			local relative = files[index]
			if not relative then
				break
			end
			index = index + 1
			local file = vim.fs.joinpath(run.root, relative)
			local ft = vim.filetype.match({ filename = file })
			for _, config in ipairs(by_ft[ft] or {}) do
				local key = config.name .. "\0" .. vim.fs.dirname(file) .. "\0" .. ft
				if not seen[key] then
					seen[key] = true
					jobs[#jobs + 1] = { config = config, file = file, ft = ft }
				end
			end
		end
		if files[index] then
			vim.defer_fn(step, 1)
		else
			callback(jobs)
		end
	end

	step()
end

local function discover(run)
	local by_ft = configs_by_filetype()
	run.status = "scanning"
	run.scan = vim.system(
		scan_command,
		{ cwd = run.root, timeout = SCAN_TIMEOUT_MS },
		vim.schedule_wrap(function(result)
			if not alive(run) then
				return
			end
			run.scan = nil
			-- rg exits 1 when it admits no files at all.
			if result.code ~= 0 and result.code ~= 1 then
				run.status = "scan failed: " .. vim.trim(result.stderr or tostring(result.code))
				return
			end
			local files = vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })
			table.sort(files)
			classify(run, files, by_ft, function(jobs)
				resolve_all(run, jobs)
			end)
		end)
	)
end

--- Follow project mode: cancel the previous project's run, and start
--- discovery for `root` once any session restore has settled.
function M.project_changed(root)
	root = path.normalize(root)
	if active and active.root == root then
		return
	end
	cancel()
	if not root or vim.g.nvim_preview then
		return
	end
	local enabled, err = is_enabled(root)
	local run = { root = root, probes = {}, seeds = {}, entries = {}, skipped = {}, status = err or "disabled" }
	active = run
	if not enabled then
		return
	end
	run.status = "waiting for project restore"
	local function launch()
		if not alive(run) then
			return
		end
		if session.restore_in_progress() then
			vim.defer_fn(launch, 150)
			return
		end
		local ok, failure = pcall(discover, run)
		if not ok then
			run.status = "startup failed: " .. tostring(failure)
		end
	end
	vim.defer_fn(launch, 150)
end

function M.toggle()
	local root = require("project-manager.state").is_open() and require("project-manager.root").current() or nil
	if not root then
		vim.notify("Open a project before toggling automatic LSP startup", vim.log.levels.WARN)
		return
	end
	local enabled = not is_enabled(root)
	local ok, err = set_enabled(root, enabled)
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return
	end
	cancel()
	M.project_changed(root)
	vim.notify("Project LSP startup " .. (enabled and "enabled" or "disabled") .. " · " .. root)
end

--- Report lines for the project info panel.
function M.info(root)
	local enabled, err = is_enabled(root)
	local lines = { "auto LSP:    " .. (enabled and "enabled" or "disabled") .. " (Java excluded)" }
	if err then
		lines[#lines + 1] = "  " .. err
	end
	if not active or active.root ~= root then
		return lines
	end

	lines[#lines + 1] = "  " .. active.status
	local keys = vim.tbl_keys(active.entries)
	table.sort(keys)
	for _, key in ipairs(keys) do
		local entry = active.entries[key]
		local client = entry.id and vim.lsp.get_client_by_id(entry.id)
		local status = entry.error or (client and (client.initialized and "initialized" or "starting") or "stopped")
		lines[#lines + 1] = ("  %s · %s · %s"):format(entry.name, entry.root, status)
	end
	for name, reason in pairs(active.skipped) do
		lines[#lines + 1] = ("  %s · skipped: %s"):format(name, reason)
	end
	return lines
end

function M.setup()
	local group = vim.api.nvim_create_augroup("ProjectLspSeeds", { clear = true })
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(ev)
			seeds[ev.buf] = nil
		end,
	})
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = function(ev)
			if not seeds[ev.buf] then
				return
			end
			seeds[ev.buf] = nil
			-- The user opened a previously hidden seed. Give normal file plugins
			-- the events suppressed during startup, without changing the window.
			vim.api.nvim_exec_autocmds("BufReadPost", { buffer = ev.buf, modeline = false })
			vim.api.nvim_exec_autocmds("FileType", { buffer = ev.buf, modeline = false })
		end,
	})
end

return M
