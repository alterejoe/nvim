local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("radioprimary", {
    t("@components.PrimarySimpleRadioButton(&structs.Radio{})"),
  }),

  s("radiosecondary", {
    t("@components.SecondarySimpleRadioButton(&structs.Radio{})"),
  }),

  s("radiotertiary", {
    t("@components.TertiarySimpleRadioButton(&structs.Radio{})"),
  }),

  s("radioquaternary", {
    t("@components.QuaternarySimpleRadioButton(&structs.Radio{})"),
  }),

  s("radioaccent", {
    t("@components.AccentSimpleRadioButton(&structs.Radio{})"),
  }),

  s("radiounique", {
    t("@components.UniqueSimpleRadioButton(&structs.Radio{})"),
  }),

  s("radioattention", {
    t("@components.AttentionSimpleRadioButton(&structs.Radio{})"),
  }),

  s("radiotransparent", {
    t("@components.TransparentSimpleRadioButton(&structs.Radio{})"),
  }),

}
