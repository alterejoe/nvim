local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("linkbtnprimary", {
    t("@components.PrimaryLinkButton(&structs.Link{})"),
  }),

  s("linkbtnsecondary", {
    t("@components.SecondaryLinkButton(&structs.Link{})"),
  }),

  s("linkbtntertiary", {
    t("@components.TertiaryLinkButton(&structs.Link{})"),
  }),

  s("linkbtnquaternary", {
    t("@components.QuaternaryLinkButton(&structs.Link{})"),
  }),

  s("linkbtnaccent", {
    t("@components.AccentLinkButton(&structs.Link{})"),
  }),

  s("linkbtnunique", {
    t("@components.UniqueLinkButton(&structs.Link{})"),
  }),

  s("linkbtnattention", {
    t("@components.AttentionLinkButton(&structs.Link{})"),
  }),

  s("linkbtntransparent", {
    t("@components.TransparentLinkButton(&structs.Link{})"),
  }),

}
