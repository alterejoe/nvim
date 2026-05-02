local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("linkprimary", {
    t("@components.PrimaryLink(&structs.Link{})"),
  }),

  s("linksecondary", {
    t("@components.SecondaryLink(&structs.Link{})"),
  }),

  s("linktertiary", {
    t("@components.TertiaryLink(&structs.Link{})"),
  }),

  s("linkaccent", {
    t("@components.AccentLink(&structs.Link{})"),
  }),

  s("linkunique", {
    t("@components.UniqueLink(&structs.Link{})"),
  }),

  s("linkattention", {
    t("@components.AttentionLink(&structs.Link{})"),
  }),

  s("link", {
    t("@components.DefaultLink(&structs.Link{})"),
  }),

}
