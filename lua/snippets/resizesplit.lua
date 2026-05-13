local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("resizesplitvertical", {
    t("@components.VerticalResizeSplit(&structs.ResizeSplit{})"),
  }),

  s("resizesplithorizontal", {
    t("@components.HorizontalResizeSplit(&structs.ResizeSplit{})"),
  }),

}
