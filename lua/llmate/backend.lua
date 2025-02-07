local debug = require("llmate.debug")

local M = {}

local backend = os.getenv("LLMATE_BACKEND")
if backend == "rust" then
  backend = "rust"
else
  -- use curl by default
  backend = "curl"
end

debug.log("LLMATE_BACKEND: " .. backend)

local function curl_chat_stream(chat_req, callback)
  local url = string.format("%s/chat/completions", chat_req.api_base)

  -- convert all line break in the prompt to '\n'
  local prompt = chat_req.prompt:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n"):gsub('"', '\\"'):gsub("'", "\\'"):gsub("`", "\\`"):gsub("{", "\\{"):gsub("}", "\\}")

  -- Format the data for the request
  local data = string.format([[
        {
            "model": "%s",
            "messages": [{"role": "user", "content": "%s"}],
            "stream": true
        }
    ]], chat_req.model, prompt)

  -- Function to properly escape JSON for shell
  local function escape_json_for_shell(json_str)
    -- Replace backslashes first to avoid double escaping
    json_str = json_str:gsub("\\", "\\\\")
    -- Escape double quotes
    json_str = json_str:gsub('"', '\\"')
    -- Escape single quotes (though we'll use double quotes for the outer shell command)
    json_str = json_str:gsub("'", "\\'")
    json_str = json_str:gsub("`", "\\`")
    return json_str
  end

  -- Escape the JSON payload
  local escaped_data = escape_json_for_shell(data)

  -- Ensure the entire JSON payload is escaped correctly for curl
  -- Use double quotes for the outer shell command, and escape internal quotes
  local command = string.format([[
        curl -s -X POST %s \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer %s" \
        -d "%s"
    ]], url, chat_req.api_key, escaped_data)

  debug.log(command)

  local bufferred_line = nil
  -- Use vim.fn.jobstart for true asynchronous execution
  local _ = vim.fn.jobstart({'bash', '-c', command}, {
    stdout_buffered = false,
    pty = true,
    on_stdout = function(_, lines, _)
      -- local timestamp = os.date("%Y-%m-%d %H:%M:%S")
      -- print("on_stdout: " .. timestamp)

      for _, line in ipairs(lines) do
        if line ~= "" then
          if line:match('^data: %[DONE%]') then
            print("[END] Stream finished.")
            vim.schedule(function()
              callback("[[DONE]]")
            end)
            break
          end

          -- WARN: in real world, the first "data: " might be broken by two on_stdout events
          if line:match('^data') and not line:match('}]}$') then
            bufferred_line = line
            goto continue
          elseif not line:match('^data') and line:match('}]}$') then
            bufferred_line = bufferred_line .. line
          elseif line:match('^data') and line:match('}]}$') then
            bufferred_line = line
          end

          if bufferred_line then
            local json_str = bufferred_line:sub(7)  -- remove the 'data: ' prefix
            bufferred_line = nil

            local success, parsed_data = pcall(function()
              return vim.fn.json_decode(json_str)
            end)

            if success and parsed_data and parsed_data.choices then
              for _, choice in ipairs(parsed_data.choices) do
                if choice.delta and choice.delta.content then
                  callback(choice.delta.content)
                  debug.log(choice.delta.content)
                end
                if choice.finish_reason == "stop" then
                  print("[END] Stream completed.")
                end
              end
            else
              print("JSON Parsing Error: " .. tostring(parsed_data))
              print("Original JSON string: " .. json_str)
            end
          end
        end
        ::continue::
      end
    end,
    on_stderr = function(_, lines, _)
      for _, line in ipairs(lines) do
        if line ~= "" then
          print("Error: " .. line)
        end
      end
    end,
    on_exit = function(_, code, _)
      debug.log(string.format("Job exited with code %d", code))
    end
  })
end

M.chat_stream = function (chat_req, callback)
  if backend == "rust" then
    require("backend").chat_stream(chat_req, callback)
  elseif backend == "curl" then
    curl_chat_stream(chat_req, callback)
  end
end

local function parse_prompts(yaml_text)
  -- 辅助函数：解析多行文本块
  local function parse_block_scalar(lines, start)
    local content = {}
    local base_indent = nil
    local i = start

    while i <= #lines do
      local line = lines[i]
      local current_indent = line:match("^(%s*)") or ""

      -- 检查是否属于当前块
      if line:match("^%s") then
        if line:match("^%s*$") then
          -- 空行保留为空字符串
          table.insert(content, "")
        else
          -- 确定基准缩进
          if not base_indent then
            base_indent = current_indent
          end
          -- 检查缩进是否足够
          if #current_indent >= #base_indent then
            local stripped_line = line:sub(#base_indent + 1)
            table.insert(content, stripped_line)
          else
            break
          end
        end
        i = i + 1
      else
        -- empty line, need to check next line's indent
        if not lines[i + 1] then
          break
        end
        local next_line_indent = lines[i + 1]:match("^(%s*)") or ""
        if #next_line_indent < #base_indent then
          break
        end

        table.insert(content, "")

        i = i + 1
      end
    end

    return table.concat(content, "\n"), i - 1
  end

  -- 分割文本为行数组
  local lines = {}
  for line in yaml_text:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end

  local result = {
    prompt_template = "",
    prompts = {}
  }

  local i = 1
  while i <= #lines do
    local line = lines[i]

    -- 解析 prompt_template
    if line:match("^prompt_template:") then
      local block_start = line:match("|%-?$")
      if block_start then
        local content, new_i = parse_block_scalar(lines, i + 1)
        result.prompt_template = content
        i = new_i
      else
        i = i + 1
      end

      -- 解析 prompts 列表
    elseif line:match("^prompts:") then
      i = i + 1
      while i <= #lines do
        local current_line = lines[i]
        if current_line:match("^%s*-") then
          -- 解析单个提示项
          local title = current_line:match("title:%s*(.*)")
          local prompt = {
            title = title and title:gsub("%s+$", "") or "",
            text = ""
          }

          -- 查找text字段
          i = i + 1
          while i <= #lines do
            local text_line = lines[i]
            if text_line:match("^%s+text:") then
              if text_line:match("|%-?%s*$") then
                local content, new_i = parse_block_scalar(lines, i + 1)
                prompt.text = content
                i = new_i
              else
                prompt.text = text_line:match("text:%s*(.*)")
                i = i + 1
              end
              break
            elseif not text_line:match("^%s") then
              break
            else
              i = i + 1
            end
          end

          table.insert(result.prompts, prompt)
        else
          i = i + 1
        end
      end
    else
      i = i + 1
    end
  end

  return result
end

local function parse_config(yaml_text)
  local config_table = {}
  for line in yaml_text:gmatch("[^\r\n]+") do -- 逐行读取文本
    local trimmed_line = line:match("^%s*(.-)%s*$") -- 去除行首尾空格
    if trimmed_line ~= "" and not trimmed_line:match("^#") then -- 排除空行和注释行
      local key, value = trimmed_line:match("([^:]+):%s*(.*)") -- 使用冒号分割键值
      if key and value then
        config_table[key] = value
      end
    end
  end
  return config_table
end

local function prompts_to_string(prompt_set)
  local result = {}

  local template = prompt_set.prompt_template
  table.insert(result, "prompt_template: |-")

  -- splite template with new line
  for line in template:gmatch("([^\n]*)\n?") do
    table.insert(result, "  " .. line)
  end
  -- remove the last empty line in result
  if result[#result] == "  " then
    table.remove(result)
  end

  table.insert(result, "prompts:")
  for _, prompt in ipairs(prompt_set.prompts) do
    table.insert(result, "- title: " .. prompt.title)
    -- check if prompt.text has multiple lines
    if prompt.text:match("\n") then
      table.insert(result, "  text: |-")
      for line in prompt.text:gmatch("([^\n]*)\n?") do
        table.insert(result, "    " .. line)
      end
      -- remove the last empty line in result
      if result[#result] == "    " then
        table.remove(result)
      end
    else
      table.insert(result, "  text: " .. prompt.text)
    end
  end
  return table.concat(result, "\n")
end

M.read_config_set = function(config_path)
  if backend == "rust" then
    return require("backend").read_config_set(config_path)
  elseif backend == "curl" then
    local file, err = io.open(config_path, "r")
    if file then
      local content = file:read("*a")
      file:close()
      return parse_config(content)
    else
      debug.log(err)
      return nil
    end
  end
end

M.write_prompt_set = function(file_path, prompt_set)
  if backend == "rust" then
    require("backend").write_prompt_set(file_path, prompt_set)
  elseif backend == "curl" then
    local prompts_str = prompts_to_string(prompt_set)
    local file, err = io.open(file_path, "w")
    if file then
      file:write(prompts_str)
      file:close()
    else
      debug.log(err)
    end
  end
end

M.read_prompt_set = function(file_path)
  if backend == "rust" then
    return require("backend").read_prompt_set(file_path)
  elseif backend == "curl" then
    local file, err = io.open(file_path, "r")
    if file then
      local content = file:read("*a")
      file:close()
      return parse_prompts(content)
    else
      debug.log(err)
      return nil
    end
  end
end

return M
