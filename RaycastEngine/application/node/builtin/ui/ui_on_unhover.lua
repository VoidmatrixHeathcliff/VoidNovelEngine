local Common = require("application.node.builtin.ui._ui_event_entry_common")

return Common.create_definition(
{
    type_id = "ui_on_unhover",
    icon_id = "send-plane-2-fill",
    color = Common.color,
    name = "组件结束悬停",
    comment = "鼠标离开时触发",
    order = 6,
    filter_list =
    {
        {key = "widget_id_filter", name = "组件名称"},
    },
    matches = function(self, event_context, payload, read_filter_text)
        if tostring(event_context.event_type or "") ~= "on_unhover" then
            return false
        end

        local widget_id_filter = read_filter_text(self, "widget_id_filter")
        if widget_id_filter ~= ""
            and widget_id_filter ~= tostring(payload.widget_id or "")
            and widget_id_filter ~= tostring(payload.widget_name or "")
        then
            return false
        end
        return true
    end,
})
