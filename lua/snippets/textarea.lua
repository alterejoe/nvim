local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("textareaprimary", {
    t("@components.PrimaryTextarea(&structs.Textarea{})"),
  }),

  s("textareasecondary", {
    t("@components.SecondaryTextarea(&structs.Textarea{})"),
  }),

  s("textareatertiary", {
    t("@components.TertiaryTextarea(&structs.Textarea{})"),
  }),

  s("textareaquaternary", {
    t("@components.QuaternaryTextarea(&structs.Textarea{})"),
  }),

  s("textareaaccent", {
    t("@components.AccentTextarea(&structs.Textarea{})"),
  }),

  s("textareaunique", {
    t("@components.UniqueTextarea(&structs.Textarea{})"),
  }),

  s("textareaattention", {
    t("@components.AttentionTextarea(&structs.Textarea{})"),
  }),

  s("textarea", {
    t("@components.DefaultTextarea(&structs.Textarea{})"),
  }),

}
