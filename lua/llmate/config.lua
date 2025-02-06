local backend = require("llmate.backend")

local M = {}

local DEFAULT_PROMPT_SET = {
  prompt_template = [[
Here is some text user select from a file:

  {{selected_text}}

Here is user want to do with this text:

  {{prompt}}

Give me the result:
  ]],
  prompts = {
    {
      title = "What is ...",
      text = "What is this?",
    },
    {
      title = "Explain code",
      text = "What is this code doing?",
    },
    {
      title = "Translate to English",
      text = "Translate the following text to English: ",
    },
    {
      title = "Translate to Chinese",
      text = "Translate the following text to Chinese: ",
    },
    {
      title = "Translate to German",
      text = "Translate the following text to German: ",
    },
    {
      title = "Summarize",
      text = "Summarize the following text: ",
    },
  }
}

local PROMPTS_FILE_NAME = "prompts.yaml"
local CONFIG_FILE_NAME = "config.yaml"

-- get file seperator for current OS
local FILESEP = package.config:sub(1, 1)

M.load_config_set = function(plugin_config)
  local config_path = plugin_config.data_path
  if config_path == nil then
    config_path = os.getenv("XDG_CONFIG_HOME")
      or (os.getenv("HOME") .. FILESEP .. ".config" .. FILESEP .. "llmate")
  end

  -- check if data_path existed, otherwise create it
  if not vim.loop.fs_stat(config_path) then
    vim.fn.mkdir(config_path, "p")
  end

  config_path = config_path .. FILESEP .. CONFIG_FILE_NAME

  -- check file existed
  if not vim.loop.fs_stat(config_path) then
    print("config file not found at: " .. config_path)
    return nil
  end

  return backend.read_config_set(config_path)
end

M.load_prompt_set = function(plugin_config)
  local data_path = plugin_config.data_path
  -- check nil
  if data_path == nil then
    data_path = os.getenv("XDG_CONFIG_HOME")
      or (os.getenv("HOME") .. FILESEP .. ".config" .. FILESEP .. "llmate")
  end

  -- check if data_path existed, or create it
  if not vim.loop.fs_stat(data_path) then
    vim.fn.mkdir(data_path, "p")
  end

  local file_path = data_path .. FILESEP .. PROMPTS_FILE_NAME

  -- check if file existed
  if not vim.loop.fs_stat(file_path) then
    backend.write_prompt_set(file_path, DEFAULT_PROMPT_SET)
    return DEFAULT_PROMPT_SET
  end

  local prompt_set = backend.read_prompt_set(file_path)
  print("read prompt set from: " .. file_path)
  -- print all in prompt_set
  for k, v in pairs(prompt_set) do
    print(k, v)
  end
  return prompt_set
end

M.write_prompt_set = function(plugin_config, prompt_set)
  local data_path = plugin_config.data_path
  -- check nil
  if data_path == nil then
    data_path = os.getenv("XDG_CONFIG_HOME")
      or (os.getenv("HOME") .. FILESEP .. ".config" .. FILESEP .. "llmate")
  end
  local file_path = data_path .. FILESEP .. PROMPTS_FILE_NAME

  backend.write_prompt_set(file_path, prompt_set)
end

return M
