local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("sseappend", {
    t("@components.AppendSSE(&structs.SSEChannel{})"),
  }),

  s("sseget", {
    t("@components.GetSSE(&structs.SSEChannel{})"),
  }),

  s("ssegettarget", {
    t("@components.GetTargetSSE(&structs.SSEChannel{})"),
  }),

  s("sseappendtarget", {
    t("@components.AppendTargetSSE(&structs.SSEChannel{})"),
  }),

}
