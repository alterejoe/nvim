local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("destructiveconfirmdialogsm", {
    t("@components.SMDestructiveConfirmDialog(&structs.DestructiveConfirmDialog{})"),
  }),

  s("destructiveconfirmdialogmd", {
    t("@components.MDDestructiveConfirmDialog(&structs.DestructiveConfirmDialog{})"),
  }),

}
