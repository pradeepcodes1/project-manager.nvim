local M = {}

local pruner = require("project-manager.actions.pruner")
local project_state = require("project-manager.state")
local project_paths = require("project-manager.paths")
local cli = require("project-manager.util.cli")
local path_util = require("project-manager.util.path")

local function session_picker(title, confirm)
	-- Stale entries are pruned at startup, so this picker needs no cleanup action.
	return Snacks.picker.pick({
		title = title,
		format = function(item)
			return { { item.text, item.stale and "Comment" or "Normal" } }
		end,
		layout = { preset = "select" },
		finder = function()
			return project_state.session_list()
		end,
		transform = function(item)
			item.stale = pruner.stale_session(item)
			item.text = item.display_name .. (item.stale and " (missing directory)" or "")
			item.file = item.path
		end,
		confirm = confirm,
	})
end

M.session_picker = session_picker

function M.open_directory()
	local confirmed = false
	-- Keep project selection local to this Yazi window; ordinary file-manager exits still cancel.
	require("yazi").yazi({
		keymaps = false,
		change_neovim_cwd_on_close = false,
		open_file_function = function() end,
		hooks = {
			-- Yazi reports readiness from a fast event; keymaps and notifications need the main loop.
			on_yazi_ready = vim.schedule_wrap(function(buffer, _, api)
				if not vim.api.nvim_buf_is_valid(buffer) then
					return
				end
				-- Terminal-local, and only while this Yazi buffer exists.
				vim.keymap.set("t", "<c-o>", function()
					confirmed = true
					api:emit_to_yazi({ "quit" })
				end, { buffer = buffer, desc = "Open current directory as project" })
				vim.notify("Yazi: enter the project directory, then Ctrl-o to open; q to cancel")
			end),
			yazi_closed_successfully = function(_, _, state)
				if not confirmed or not state.last_directory then
					return
				end
				local root = path_util.normalize(state.last_directory.filename)
				if not root or vim.fn.isdirectory(root) ~= 1 then
					vim.notify("Project directory does not exist", vim.log.levels.WARN)
					return
				end
				-- Ctrl-o selects a project for this editor, so restore it here after Yazi closes.
				vim.schedule(function()
					local sessions = require("auto-session")
					local branch = cli.git_branch(root) or ""
					for _, entry in ipairs(project_state.session_list()) do
						local entry_root, entry_branch = entry.session_name:match("^([^|]*)|?(.*)$")
						if path_util.normalize(entry_root) == root and entry_branch == branch then
							sessions.autosave_and_restore(entry.session_name)
							return
						end
					end
					-- Preserve the current project before making a fresh one in this window.
					if project_state.is_open() then
						sessions.save_session(nil, { show_message = false })
					end
					vim.cmd({ cmd = "cd", args = { root }, mods = { noautocmd = true } })
					vim.cmd.enew()
					project_state.set_open(true, root)
					sessions.save_session(nil, { show_message = false })
				end)
			end,
			-- File selections are not project confirmations, including multi-select opens.
			yazi_opened_multiple_files = function() end,
		},
	}, vim.fn.getcwd())
end

function M.open_session_window(session_name, directory)
	if type(session_name) ~= "string" or session_name == "" then
		return false
	end

	-- Directory launches can create a session; named launches only restore one.
	local marker = directory and "NVIM_PROJECT_DIRECTORY" or "NVIM_PROJECT_SESSION"
	local root = directory and session_name or session_name:match("^([^|]+)")
	if not root or vim.fn.isdirectory(root) ~= 1 then
		root = vim.uv.cwd()
	end

	if vim.g.neovide then
		if cli.missing("open project window", "neovide") then
			return false
		end

		local command, opts
		if vim.uv.os_uname().sysname == "Darwin" then
			-- Launch through the app bundle so macOS and OmniWM see Neovide's stable
			-- bundle ID. `-n` creates a separate GUI instance instead of forwarding
			-- the request to the Neovide window that owns this picker.
			if cli.missing("open project window", "open") then
				return false
			end
			local executable = vim.uv.fs_realpath(vim.fn.exepath("neovide")) or vim.fn.exepath("neovide")
			local bundle = executable:match("^(.*%.app)/Contents/MacOS/") or "Neovide"
			command = { "open", "-na", bundle, "--env", marker .. "=" .. session_name }
			opts = {}
		else
			-- There is no bundle to route through elsewhere: every `neovide` call is
			-- already a separate process, so launch it directly and hand the session
			-- over in the environment, exactly as the Kitty branch below does.
			command = { "neovide", "--no-fork", "--", "--cmd", "cd " .. vim.fn.fnameescape(root) }
			opts = { env = { [marker] = session_name } }
		end

		return cli.detach("open project in a new Neovide window", command, opts)
	end

	if cli.missing("open project window", "kitty", "nvim") then
		return false
	end

	local title = ("Project · %s"):format(vim.fn.fnamemodify(root, ":t"))
	return cli.detach("open project in a new Kitty window", cli.kitty_argv(root, title, "nvim"), {
		env = { [marker] = session_name },
	})
end

function M.open_picked_session(session_name)
	if project_state.is_open() then
		return M.open_session_window(session_name)
	end
	return require("auto-session").autosave_and_restore(session_name)
end

-- auto-session's own picker always restores in place. this one routes the
-- choice through open_picked_session, which opens a new kitty window instead
-- when a project is already loaded here.
function M.pick_session()
	session_picker("Projects", function(picker, item)
		if item and pruner.stale_session(item) then
			vim.notify(
				"Project directory is missing; its stale session will be pruned on the next start.",
				vim.log.levels.WARN
			)
			return
		end
		picker:close()
		if item then
			vim.schedule(function()
				M.open_picked_session(item.session_name)
			end)
		end
	end)
end

-- Symbol and reference pickers are scoped to the project, which is what keeps
-- jdtls' decompiled jdt:// classfiles, dependency sources and toolchain
-- libraries out of them. <C-.> widens the picker to everything the servers
-- actually index, for the times a JDK or library symbol is the thing you want.
--
-- No action is written for this: Snacks generates a `toggle_<name>` action for
-- every entry in `toggles`, which flips `picker.opts[name]` and re-finds. The
-- item predicate cannot see the picker, so `transform` -- which can -- copies
-- the flag onto the filter's own meta and returns true to force the refresh.
-- `root` is required, and a nil one means unscoped rather than "fall back to
-- current_root()". That fallback would scope a file belonging to no project to
-- whatever repo Neovim happened to start in, filtering away every result the
-- server returned -- the exact failure this is supposed to prevent.
function M.picker_scope(root)
	if not root then
		return {}
	end

	return {
		toggles = { external = { icon = "e" } },
		-- Deliberately `transform` and not `filter.cwd`. Only the location
		-- sources apply the picker's Filter -- lsp/init.lua calls filter:match
		-- inside get_locations, which serves gr -- while the symbol finder
		-- ignores it entirely, so a filter here would scope gr and silently do
		-- nothing for fS. Finder:run applies `transform` for every source, and
		-- returning false from it drops the item.
		transform = function(item, ctx)
			if ctx.picker.opts.external then
				return
			end
			if not path_util.under(item.file, root) then
				return false
			end
		end,
		-- <c-.> mirrors the ignored-files toggle the snacks pickers bind it to;
		-- here the equivalent widening is showing sessions outside this root.
		win = {
			input = { keys = { ["<c-.>"] = { "toggle_external", mode = { "i", "n" } } } },
			list = { keys = { ["<c-.>"] = "toggle_external" } },
		},
	}
end

--- The same project in a second window. open_session_window restores by session
--- name in the new instance, so save first: an unsaved project has no name to
--- hand over, and the macOS Neovide branch has no directory of its own to fall
--- back on if that restore fails.
function M.open_new_window()
	if not project_state.is_open() then
		return false
	end

	require("auto-session").save_session(nil, { show_message = false })
	local session_name = project_state.current_session_name()
	if not session_name then
		vim.notify("Cannot open a second window: this project has no session", vim.log.levels.ERROR)
		return false
	end

	return M.open_session_window(session_name)
end

--- A native terminal split at the project root. Not gated on project mode:
--- current_root() answers for a lone file too, and its directory is still
--- where a shell belongs.
function M.open_terminal()
	local root = project_paths.current_root() or path_util.cwd()
	if not root then
		return false
	end

	vim.cmd("botright 15new")
	vim.cmd({ cmd = "lcd", args = { root } })
	vim.cmd.terminal()
	vim.cmd.startinsert()
	return true
end

return M
