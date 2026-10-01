local M = {}
local project_pickers = require("project-manager.actions.pickers")
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
function M.delete_session()
	project_pickers.session_picker("Delete project session", function(picker)
		local items = picker:selected({ fallback = true })
		if #items == 0 then
			picker:close()
			return
		end

		local sessions = require("auto-session")
		for _, item in ipairs(items) do
			sessions.delete_session_file(item.path, item.display_name)
		end
		picker.list:set_selected()
		picker:find()
	end)
end

return M
