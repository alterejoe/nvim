local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("btnprimary", {
    t("@components.PrimaryButton(&structs.Button{})"),
  }),

  s("btnsecondary", {
    t("@components.SecondaryButton(&structs.Button{})"),
  }),

  s("btntertiary", {
    t("@components.TertiaryButton(&structs.Button{})"),
  }),

  s("btnquaternary", {
    t("@components.QuaternaryButton(&structs.Button{})"),
  }),

  s("btnaccent", {
    t("@components.AccentButton(&structs.Button{})"),
  }),

  s("btnunique", {
    t("@components.UniqueButton(&structs.Button{})"),
  }),

  s("btnattention", {
    t("@components.AttentionButton(&structs.Button{})"),
  }),

  s("btntransparent", {
    t("@components.TransparentButton(&structs.Button{})"),
  }),

  s("btnghost", {
    t("@components.GhostButton(&structs.Button{})"),
  }),

}
