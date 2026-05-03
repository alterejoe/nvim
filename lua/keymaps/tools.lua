-- <leader>wb   start chromium + devproxy
-- <leader>wq   stop everything
-- <leader>wo   toggle devproxy log
-- <leader>wr   restart devproxy
--
-- <leader>bn   navigate partial (HX-Request: true)
-- <leader>bN   navigate full page
-- <leader>bo   open new tab
-- <leader>bt   telescope tab picker -> switch
-- <leader>bm   mobile partial
-- <leader>bM   mobile full page
-- <leader>bd   restore desktop
-- <leader>bi   re-inject CSS
-- <leader>b1   jump to admin url
-- <leader>b2   jump to statecodes url
--
-- <leader>bc   console picker
-- <leader>bq   network picker
-- <leader>bs   connect CDP
-- <leader>bx   disconnect CDP
-- require("browser_session")
vim.keymap.set("n", "<leader>hh", function()
	vim.cmd("edit!")
	print("Buffer reloaded")
end, { desc = "Reload buffer" })

vim.keymap.set("n", "<leader>mh", "<cmd>Noice history<cr>", { desc = "Noice history" })
vim.keymap.set("n", "<leader>mm", "<cmd>messages<cr>", { desc = "Noice messages" })
