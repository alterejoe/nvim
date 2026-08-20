local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("statusthumbnail", {
    t("@components.StatusThumbnail(&structs.StatusThumbnail{})"),
  }),

}
