local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("formfooterprimary", {
    t("@components.PrimaryFormFooter(&structs.FormFooter{})"),
  }),

  s("formfootersecondary", {
    t("@components.SecondaryFormFooter(&structs.FormFooter{})"),
  }),

  s("formfootertertiary", {
    t("@components.TertiaryFormFooter(&structs.FormFooter{})"),
  }),

  s("formfooterquaternary", {
    t("@components.QuaternaryFormFooter(&structs.FormFooter{})"),
  }),

  s("formfooteraccent", {
    t("@components.AccentFormFooter(&structs.FormFooter{})"),
  }),

  s("formfooterunique", {
    t("@components.UniqueFormFooter(&structs.FormFooter{})"),
  }),

  s("formfooterattention", {
    t("@components.AttentionFormFooter(&structs.FormFooter{})"),
  }),

  s("formfooterneutral", {
    t("@components.NeutralFormFooter(&structs.FormFooter{})"),
  }),

}
