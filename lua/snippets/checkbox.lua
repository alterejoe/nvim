local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("checkprimary", {
    t("@components.PrimaryCheckbox(&structs.Checkbox{})"),
  }),

  s("checksecondary", {
    t("@components.SecondaryCheckbox(&structs.Checkbox{})"),
  }),

  s("checktertiary", {
    t("@components.TertiaryCheckbox(&structs.Checkbox{})"),
  }),

  s("checkquaternary", {
    t("@components.QuaternaryCheckbox(&structs.Checkbox{})"),
  }),

  s("checkaccent", {
    t("@components.AccentCheckbox(&structs.Checkbox{})"),
  }),

  s("checkunique", {
    t("@components.UniqueCheckbox(&structs.Checkbox{})"),
  }),

  s("checkattention", {
    t("@components.AttentionCheckbox(&structs.Checkbox{})"),
  }),

  s("checktransparent", {
    t("@components.TransparentCheckbox(&structs.Checkbox{})"),
  }),

}
