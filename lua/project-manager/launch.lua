-- Opening projects: in this editor, in a new editor process, or as a terminal.
local M = {}

local cli = require("project-manager.util.cli")
local path = require("project-manager.util.path")
local session = require("project-manager.session")
local state = require("project-manager.state")

-- A new process learns what to open from its environment. Only picker-launched
-- instances receive these, so ordinary file launches stay file-only.
-- Directory launches can create a session; named launches only restore one.
local DIRECTORY_MARKER = "NVIM_PROJECT_DIRECTORY"
local SESSION_MARKER = "NVIM_PROJECT_SESSION"

--- Make `root` this editor's project with an empty workspace and save it, so
--- the new session is named after this root.
local function start_fresh(root)
	-- A session restored by name (an editor launched outside its root, like
	-- Neovide from the Dock) keeps answering save_session(nil) after a
	-- noautocmd cd, which would overwrite that project with this root. Forget
	-- it the way auto-session's own DirChangedPre does.
	vim.v.this_session = ""
	vim.cmd({ cmd = "cd", args = { root }, mods = { noautocmd = true } })
	vim.cmd.enew()
	state.set_open(true, root)
	require("auto-session").save_session(nil, { show_message = false })
end

--- Open `root` as the project in this editor: restore its session, or start a
--- fresh one after saving the project being left.
function M.open_root(root)
	local sessions = require("auto-session")
	local entry = session.find(root)
	if entry then
		-- Project mode follows the restore here rather than trusting the
		-- user's auto-session hooks to switch it, as the fresh branch does.
		if sessions.autosave_and_restore(entry.session_name) then
			state.set_open(true, root)
		end
		return
	end

	if state.is_open() then
		sessions.save_session(nil, { show_message = false })
	end
	start_fresh(root)
end

--- A new editor process for `session_name`, or for the directory it names
--- when `directory` is set. Neovide when this is Neovide, Kitty otherwise.
local function open_window(session_name, directory)
	if type(session_name) ~= "string" or session_name == "" then
		return false
	end

	local marker = directory and DIRECTORY_MARKER or SESSION_MARKER
	local root = directory and session_name or session.parse_name(session_name)
	if not root or vim.fn.isdirectory(root) ~= 1 then
		root = vim.uv.cwd()
	end

	if vim.g.neovide then
		if cli.missing("open project window", "neovide") then
			return false
		end

		local command, opts
		if vim.uv.os_uname().sysname == "Darwin" then
			-- Launch through the app bundle so macOS and window managers see
			-- Neovide's stable bundle ID. `-n` creates a separate GUI instance
			-- instead of forwarding the request to the Neovide window that
			-- owns this picker.
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
	local command = { "kitty", "--detach", "--directory", root, "--title", title, "nvim" }
	return cli.detach("open project in a new Kitty window", command, { env = { [marker] = session_name } })
end

--- Restore `session_name` here, or in a new window when this editor already
--- holds a project.
function M.open_session(session_name)
	if state.is_open() then
		return open_window(session_name)
	end
	if not require("auto-session").autosave_and_restore(session_name) then
		return false
	end
	state.set_open(true, (session.parse_name(session_name)))
	return true
end

--- The same project in a second window. open_window restores by session name
--- in the new instance, so save first: an unsaved project has no name to hand
--- over, and the macOS Neovide branch has no directory of its own to fall
--- back on if that restore fails.
function M.new_window()
	if not state.is_open() then
		return false
	end

	require("auto-session").save_session(nil, { show_message = false })
	local session_name = session.current_name()
	if not session_name then
		vim.notify("Cannot open a second window: this project has no session", vim.log.levels.ERROR)
		return false
	end

	return open_window(session_name)
end

--- A native terminal split at the project root. Not gated on project mode:
--- root.current() answers for a lone file too, and its directory is still
--- where a shell belongs.
function M.terminal()
	local root = require("project-manager.root").current() or path.cwd()
	if not root then
		return false
	end

	vim.cmd("botright 15new")
	vim.cmd({ cmd = "lcd", args = { root } })
	vim.cmd.terminal()
	vim.cmd.startinsert()
	return true
end

--- At startup, open whatever the launching editor asked this process for.
--- Directory launches are made in their own process so the launcher's
--- workspace never changes.
function M.restore_requested()
	local directory, session_name = vim.env[DIRECTORY_MARKER], vim.env[SESSION_MARKER]
	vim.env[DIRECTORY_MARKER], vim.env[SESSION_MARKER] = nil, nil

	if directory and directory ~= "" then
		vim.schedule(function()
			local root = path.normalize(directory)
			if not root or vim.fn.isdirectory(root) ~= 1 then
				vim.notify("Project directory does not exist", vim.log.levels.ERROR)
				return
			end
			vim.cmd({ cmd = "cd", args = { root }, mods = { noautocmd = true } })
			if not session.exists(root) then
				start_fresh(root)
			elseif require("auto-session").restore_session(nil, { show_message = false }) then
				state.set_open(true, root)
			end
		end)
	elseif session_name and session_name ~= "" then
		state.set_open(true, (session.parse_name(session_name)))
		vim.schedule(function()
			local restored = require("auto-session").restore_session(
				session_name,
				{ is_startup_autorestore = true, show_message = false }
			)
			if not restored then
				state.set_open(false)
			end
		end)
	end
end

return M
