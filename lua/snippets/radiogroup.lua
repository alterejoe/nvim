local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("radiogroup", {
    t("@components.PrimaryRadioGroup(&structs.RadioGroup{})"),
  }),

  s("radiogroup", {
    t("@components.AccentRadioGroup(&structs.RadioGroup{})"),
  }),

  s("radiogroup", {
    t("@components.SecondaryRadioGroup(&structs.RadioGroup{})"),
  }),

  s("radiogroup", {
    t("@components.AttentionRadioGroup(&structs.RadioGroup{})"),
  }),

  s("radiogroup", {
    t("@components.UniqueRadioGroup(&structs.RadioGroup{})"),
  }),

}
