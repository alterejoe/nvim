local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("inputprimary", {
    t("@components.PrimaryInput(&structs.Input{})"),
  }),

  s("inputsecondary", {
    t("@components.SecondaryInput(&structs.Input{})"),
  }),

  s("inputtertiary", {
    t("@components.TertiaryInput(&structs.Input{})"),
  }),

  s("inputaccent", {
    t("@components.AccentInput(&structs.Input{})"),
  }),

  s("inputunique", {
    t("@components.UniqueInput(&structs.Input{})"),
  }),

  s("inputattention", {
    t("@components.AttentionInput(&structs.Input{})"),
  }),

  s("input", {
    t("@components.DefaultInput(&structs.Input{})"),
  }),

}
