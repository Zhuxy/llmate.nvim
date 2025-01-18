local M = {}

-- Store debug mode state
local is_debug = false

-- Set debug mode
---@param enabled boolean Whether debug mode is enabled
function M.set_debug(enabled)
  is_debug = enabled
end

-- Get debug mode state
---@return boolean Whether debug mode is enabled
function M.is_debug()
  return is_debug
end

-- Log debug message if debug mode is enabled
---@param msg string Message to log
---@param ... any Additional values to log
function M.log(msg, ...)
  if not is_debug then
    return
  end
  local args = {...}
  local formatted = string.format(msg, unpack(args))
  vim.notify("[llmate.nvim] " .. formatted, vim.log.levels.DEBUG)
end

return M
