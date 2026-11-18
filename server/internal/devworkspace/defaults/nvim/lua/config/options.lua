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

-- Copy to the host clipboard over OSC 52 (tmux passes it to the browser
-- terminal). The browser never answers clipboard reads, so paste from the
-- unnamed register; paste from the host with the browser's own paste.
local ok, osc52 = pcall(require, "vim.ui.clipboard.osc52")
if ok then
  local function paste()
    return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
  end
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = paste, ["*"] = paste },
  }
end
