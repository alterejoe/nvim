vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/site")
vim.filetype.add({
	extension = {
		templ = "templ",
	},
	filename = {
		["go.work"] = "gowork",
	},
	pattern = {
		[".*%.gotmpl"] = "gotmpl",
	},
})
