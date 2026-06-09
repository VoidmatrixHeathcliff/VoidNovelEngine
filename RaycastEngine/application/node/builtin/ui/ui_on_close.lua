local Common = require("application.node.builtin.ui._ui_event_entry_common")

return Common.create_definition(
{
    type_id = "ui_on_close",
    icon_id = "send-plane-2-fill",
    color = Common.color,
    name = "界面关闭后",
    comment = "关闭后触发",
    order = 2,
    filter_list = {},
    matches = function(self, event_context, payload, read_filter_text)
        if tostring(event_context.event_type or "") ~= "on_close" then
            return false
        end

        return true
    end,
})
