local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("labeledcheckbox", {
    t("@components.LabeledCheckbox(&structs.Checkbox{})"),
  }),

}
