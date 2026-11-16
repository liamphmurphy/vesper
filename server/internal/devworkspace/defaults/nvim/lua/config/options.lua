vim.opt.autoread = true

local group = vim.api.nvim_create_augroup("VesperAutoRead", { clear = true })
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "TermLeave", "TermClose" }, {
  group = group,
  callback = function()
    if vim.fn.getcmdwintype() == "" and vim.api.nvim_get_mode().mode ~= "c" then
      vim.cmd("checktime")
    end
  end,
})
