local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("radioprimary", {
    t("@components.PrimaryRadioButton(&structs.Radio{})"),
  }),

  s("radiosecondary", {
    t("@components.SecondaryRadioButton(&structs.Radio{})"),
  }),

  s("radiotertiary", {
    t("@components.TertiaryRadioButton(&structs.Radio{})"),
  }),

  s("radioquaternary", {
    t("@components.QuaternaryRadioButton(&structs.Radio{})"),
  }),

  s("radioaccent", {
    t("@components.AccentRadioButton(&structs.Radio{})"),
  }),

  s("radioghost", {
    t("@components.GhostRadioButton(&structs.Radio{})"),
  }),

}
