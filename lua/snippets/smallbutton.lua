local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("btnsmallprimary", {
    t("@components.SmallPrimarySmallButton(&structs.Button{})"),
  }),

  s("btnsmalltransparent", {
    t("@components.SmallTransparentSmallButton(&structs.Button{})"),
  }),

  s("btnsmallattention", {
    t("@components.SmallAttentionSmallButton(&structs.Button{})"),
  }),

  s("btnsmallattention", {
    t("@components.SmallAccentSmallButton(&structs.Button{})"),
  }),

}
