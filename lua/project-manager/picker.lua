-- Pickers: saved projects, a directory to open as one, and the project scope
-- that symbol and reference pickers filter to.
local M = {}

local launch = require("project-manager.launch")
local path = require("project-manager.util.path")
local session = require("project-manager.session")

--- Every saved session, with stale ones dimmed. Stale entries are pruned at
--- startup, so this picker needs no cleanup action of its own.
local function sessions(title, confirm)
	return Snacks.picker.pick({
		title = title,
		format = function(item)
			return { { item.text, item.stale and "Comment" or "Normal" } }
		end,
		layout = { preset = "select" },
		finder = session.list,
		transform = function(item)
			item.stale = session.is_stale(item)
			item.text = item.display_name .. (item.stale and " (missing directory)" or "")
			item.file = item.path
		end,
		confirm = confirm,
	})
end

-- auto-session's own picker always restores in place. This one routes the
-- choice through launch.open_session, which opens a new window instead when a
-- project is already loaded here.
function M.projects()
	sessions("Projects", function(picker, item)
		if item and item.stale then
			vim.notify(
				"Project directory is missing; its stale session will be pruned on the next start.",
				vim.log.levels.WARN
			)
			return
		end
		picker:close()
		if item then
			vim.schedule(function()
				launch.open_session(item.session_name)
			end)
		end
	end)
end

-- Sessions are keyed on root *and* branch (git_use_branch_name), so every
-- feature branch leaves one behind and nothing ever collects them. <Tab>
-- selects several and the picker re-finds rather than closing, so clearing out
-- a directory's worth is one visit.
--
-- delete_session_file, not delete_session: the list already carries the escaped
-- on-disk path, and re-deriving it from the name means re-entering
-- auto-session's private escaping. Deleting the session this instance has
-- loaded is auto-session's own special case -- it turns autosave off here and
-- says so -- so it is left alone rather than reimplemented.
function M.delete_sessions()
	sessions("Delete project session", function(picker)
		local items = picker:selected({ fallback = true })
		if #items == 0 then
			picker:close()
			return
		end

		local auto_session = require("auto-session")
		for _, item in ipairs(items) do
			auto_session.delete_session_file(item.path, item.display_name)
		end
		picker.list:set_selected()
		picker:find()
	end)
end

--- Choose a directory in Yazi and open it as the project in this editor.
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
				local root = path.normalize(state.last_directory.filename)
				if not root or vim.fn.isdirectory(root) ~= 1 then
					vim.notify("Project directory does not exist", vim.log.levels.WARN)
					return
				end
				vim.schedule(function()
					launch.open_root(root)
				end)
			end,
			-- File selections are not project confirmations, including multi-select opens.
			yazi_opened_multiple_files = function() end,
		},
	}, vim.fn.getcwd())
end

-- Symbol and reference pickers are scoped to the project, which is what keeps
-- jdtls' decompiled jdt:// classfiles, dependency sources and toolchain
-- libraries out of them. <C-.> widens the picker to everything the servers
-- actually index, for the times a JDK or library symbol is the thing you want.
--
-- No action is written for this: Snacks generates a `toggle_<name>` action for
-- every entry in `toggles`, which flips `picker.opts[name]` and re-finds. The
-- item predicate cannot see the picker, so `transform` -- which can -- reads
-- the flag off ctx.picker.
--
-- `root` is required, and a nil one means unscoped rather than "fall back to
-- root.current()". That fallback would scope a file belonging to no project to
-- whatever repo Neovim happened to start in, filtering away every result the
-- server returned -- the exact failure this is supposed to prevent.
function M.scope(root)
	if not root then
		return {}
	end

	return {
		toggles = { external = { icon = "e" } },
		-- Deliberately `transform` and not `filter.cwd`. Only the location
		-- sources apply the picker's Filter (snacks' lsp source calls
		-- filter:match inside get_locations, which serves references) while
		-- the symbol finder ignores it entirely, so a filter here would scope
		-- references and silently do nothing for workspace symbols.
		-- Finder:run applies `transform` for every source, and returning false
		-- from it drops the item.
		transform = function(item, ctx)
			if ctx.picker.opts.external then
				return
			end
			if not path.under(item.file, root) then
				return false
			end
		end,
		-- <c-.> mirrors the ignored-files toggle the snacks pickers bind it to;
		-- here the equivalent widening is showing results outside this root.
		win = {
			input = { keys = { ["<c-.>"] = { "toggle_external", mode = { "i", "n" } } } },
			list = { keys = { ["<c-.>"] = "toggle_external" } },
		},
	}
end

return M
