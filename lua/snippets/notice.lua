local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("noticeprimarysmall", {
    t("@components.PrimarySmallNotice(&structs.Notice{})"),
  }),

  s("noticeprimary", {
    t("@components.PrimaryNotice(&structs.Notice{})"),
  }),

  s("noticeprimarylarge", {
    t("@components.PrimaryLargeNotice(&structs.Notice{})"),
  }),

  s("noticesecondarysmall", {
    t("@components.SecondarySmallNotice(&structs.Notice{})"),
  }),

  s("noticesecondary", {
    t("@components.SecondaryNotice(&structs.Notice{})"),
  }),

  s("noticesecondarylarge", {
    t("@components.SecondaryLargeNotice(&structs.Notice{})"),
  }),

  s("noticetertiarysmall", {
    t("@components.TertiarySmallNotice(&structs.Notice{})"),
  }),

  s("noticetertiary", {
    t("@components.TertiaryNotice(&structs.Notice{})"),
  }),

  s("noticeteriarylarge", {
    t("@components.TertiaryLargeNotice(&structs.Notice{})"),
  }),

  s("noticeaccentsmall", {
    t("@components.AccentSmallNotice(&structs.Notice{})"),
  }),

  s("noticeaccent", {
    t("@components.AccentNotice(&structs.Notice{})"),
  }),

  s("noticeaccentlarge", {
    t("@components.AccentLargeNotice(&structs.Notice{})"),
  }),

  s("noticeuniquesmall", {
    t("@components.UniqueSmallNotice(&structs.Notice{})"),
  }),

  s("noticeunique", {
    t("@components.UniqueNotice(&structs.Notice{})"),
  }),

  s("noticeuniquelarge", {
    t("@components.UniqueLargeNotice(&structs.Notice{})"),
  }),

  s("noticeattentionsmall", {
    t("@components.AttentionSmallNotice(&structs.Notice{})"),
  }),

  s("noticeattention", {
    t("@components.AttentionNotice(&structs.Notice{})"),
  }),

  s("noticeattentionlarge", {
    t("@components.AttentionLargeNotice(&structs.Notice{})"),
  }),

  s("noticeneutralsmall", {
    t("@components.NeutralSmallNotice(&structs.Notice{})"),
  }),

  s("noticeneutral", {
    t("@components.NeutralNotice(&structs.Notice{})"),
  }),

  s("noticeneutrallarge", {
    t("@components.NeutralLargeNotice(&structs.Notice{})"),
  }),

}
