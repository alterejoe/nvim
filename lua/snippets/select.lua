local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("selectprimary", {
    t("@components.PrimarySelect(&structs.Select{})"),
  }),

  s("selectsecondary", {
    t("@components.SecondarySelect(&structs.Select{})"),
  }),

  s("selecttertiary", {
    t("@components.TertiarySelect(&structs.Select{})"),
  }),

  s("selectaccent", {
    t("@components.AccentSelect(&structs.Select{})"),
  }),

  s("selectunique", {
    t("@components.UniqueSelect(&structs.Select{})"),
  }),

  s("selectattention", {
    t("@components.AttentionSelect(&structs.Select{})"),
  }),

  s("select", {
    t("@components.DefaultSelect(&structs.Select{})"),
  }),

}
