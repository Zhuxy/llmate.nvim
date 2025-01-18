-- main module file
local module = require("llmate.module")
local debug = require("llmate.debug")

---@class Config Configuration for the llmate.nvim plugin
---@field key string Keybinding to launch the dialog (default: <leader>g)
---@field data_path string? Optional path to the directory containing configuration files
---@field debug boolean Enable debug mode for verbose logging (default: false)
local config = {
  key = "<leader>g",
  data_path = nil,
  debug = false,
}

---@class MyModule Main module for the llmate.nvim plugin
local M = {}

---@type Config
M.config = config

---Setup the plugin with user configuration
---@param args Config? Optional configuration table to override defaults
---@return nil
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})
  
  -- Initialize debug mode
  debug.set_debug(M.config.debug)
  if M.config.debug then
    debug.log("Debug mode enabled")
  end

  vim.keymap.set("x", M.config.key, "<cmd>lua require('llmate').open_dialog()<CR>", { silent = true, noremap = true })

  -- bind to a operation function
  vim.keymap.set("n", M.config.key, function()
    local set_opfunc = vim.fn[vim.api.nvim_exec2([[
          func s:set_opfunc(val)
            let &opfunc = a:val
          endfunc
          echon get(function('s:set_opfunc'), 'name')
        ]], { output = true }).output]

    set_opfunc(require('llmate').open_dialog)
    return "g@"
  end, { expr = true })
end

---Open the text generation dialog with selected text
---@return any Dialog result or nil if no text is selected
M.open_dialog = function()
  local selected_text = M.get_visual_selection()

  if selected_text == nil then
    print("No text selected")
    return
  end

  return module.open_dialog(M.config, selected_text)
end

---Get the currently selected text in visual mode or from motion in normal mode
---@return VisualSelection|nil Selected text information or nil if no selection
---@class VisualSelection
---@field lines string[] Array of selected lines
---@field filetype string Buffer's filetype
---@field start_row number Starting row of selection (1-based)
---@field end_row number Ending row of selection (1-based)
---@field start_col number Starting column of selection (1-based)
---@field end_col number Ending column of selection (1-based)
---@field bufnum number Buffer number
---@field winid number Window ID
M.get_visual_selection = function()
  local mode = vim.fn.mode()

  local bufnum = vim.api.nvim_get_current_buf()
  local winid = vim.fn.win_getid()

  local filetype = vim.api.nvim_buf_get_option(bufnum, "filetype")

  local s_start = nil
  local s_end = nil

  -- NOTE: quit v mode to normal mode
  -- mark < and > can only get postion in the last visual mode (must quit visual mode first)
  if mode == "v" then
    vim.cmd("normal! v")
  elseif mode == "V" then
    vim.cmd("normal! V")
  elseif mode == "<C-v>" then
    vim.cmd("normal! <C-v>")
  end

  -- if n mode get text from motion selection
  if mode == "n" then
    s_start = vim.fn.getpos("'[")
    s_end = vim.fn.getpos("']")
  else
    s_start = vim.fn.getpos("'<")
    s_end = vim.fn.getpos("'>")
  end

  local n_lines = math.abs(s_end[2] - s_start[2]) + 1
  local lines = vim.api.nvim_buf_get_lines(0, s_start[2] - 1, s_end[2], false)
  if next(lines) == nil then
    return nil
  end
  lines[1] = string.sub(lines[1], s_start[3], -1)
  if n_lines == 1 then
    lines[n_lines] = string.sub(lines[n_lines], 1, s_end[3] - s_start[3] + 1)
  else
    lines[n_lines] = string.sub(lines[n_lines], 1, s_end[3])
  end

  local end_col = s_end[3]
  local max_cols = vim.api.nvim_buf_get_lines(0, s_end[2] - 1, s_end[2], false)[1]:len()

  if end_col > max_cols then
    end_col = max_cols
  end

  local result = {
    lines = lines,
    filetype = filetype,
    start_row = s_start[2],
    end_row = s_end[2],
    start_col = s_start[3],
    end_col = end_col,
    bufnum = bufnum,
    winid = winid
  }

  return result
end

return M
