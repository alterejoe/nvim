local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("chevleft", {
    t("@components.ChevronChevron(&structs.Button{})"),
  }),

  s("chevright", {
    t("@components.ChevronChevron(&structs.Button{})"),
  }),

  s("chevup", {
    t("@components.ChevronChevron(&structs.Button{})"),
  }),

  s("chevdown", {
    t("@components.ChevronChevron(&structs.Button{})"),
  }),

  s("chevleftsmall", {
    t("@components.SmallChevronChevron(&structs.Button{})"),
  }),

  s("chevrightsmall", {
    t("@components.SmallChevronChevron(&structs.Button{})"),
  }),

  s("chevupsmall", {
    t("@components.SmallChevronChevron(&structs.Button{})"),
  }),

  s("chevdownsmall", {
    t("@components.SmallChevronChevron(&structs.Button{})"),
  }),

  s("chevleftprimary", {
    t("@components.PrimaryChevronChevron(&structs.Button{})"),
  }),

  s("chevrightprimary", {
    t("@components.PrimaryChevronChevron(&structs.Button{})"),
  }),

  s("chevupprimary", {
    t("@components.PrimaryChevronChevron(&structs.Button{})"),
  }),

  s("chevdownprimary", {
    t("@components.PrimaryChevronChevron(&structs.Button{})"),
  }),

  s("chevleftprimarysmall", {
    t("@components.PrimarySmallChevronChevron(&structs.Button{})"),
  }),

  s("chevrightprimarysmall", {
    t("@components.PrimarySmallChevronChevron(&structs.Button{})"),
  }),

  s("chevupprimarysmall", {
    t("@components.PrimarySmallChevronChevron(&structs.Button{})"),
  }),

  s("chevdownprimarysmall", {
    t("@components.PrimarySmallChevronChevron(&structs.Button{})"),
  }),

}
