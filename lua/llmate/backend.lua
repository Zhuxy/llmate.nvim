local debug = require("llmate.debug")

local M = {}

-- get environment variable: LLMATE_BACKEND
local backend = os.getenv("LLMATE_BACKEND")
if backend == "rust" then
  backend = "rust"
else
  backend = "curl"
end

print("LLMATE_BACKEND: " .. backend)

local function rust_chat_stream(chat_req, callback)
  require("backend").chat_stream(chat_req, callback)
end

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
    rust_chat_stream(chat_req, callback)
  elseif backend == "curl" then
    curl_chat_stream(chat_req, callback)
  end
end

M.read_config_set = function(config_path)
  if backend == "rust" then
    require("backend").read_config_set(config_path)
  elseif backend == "curl" then
    -- TODO: implement
    print("not implemented")
  end
end

M.write_prompt_set = function(file_path, prompt_set)
  if backend == "rust" then
    require("backend").write_prompt_set(file_path, prompt_set)
  elseif backend == "curl" then
    -- TODO: implement
    print("not implemented")
  end
end

M.read_prompt_set = function(file_path)
  if backend == "rust" then
    require("backend").read_prompt_set(file_path)
  elseif backend == "curl" then
    -- TODO: implement
    print("not implemented")
  end
end

return M
