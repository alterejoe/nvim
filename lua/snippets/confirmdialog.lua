local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("confirmdialogxs", {
    t("@components.XSConfirmDialog(&structs.ConfirmDialog{})"),
  }),

  s("confirmdialogsm", {
    t("@components.SMConfirmDialog(&structs.ConfirmDialog{})"),
  }),

  s("confirmdialogmd", {
    t("@components.MDConfirmDialog(&structs.ConfirmDialog{})"),
  }),

  s("confirmdialoglg", {
    t("@components.LGConfirmDialog(&structs.ConfirmDialog{})"),
  }),

  s("confirmdialogxl", {
    t("@components.XLConfirmDialog(&structs.ConfirmDialog{})"),
  }),

}
