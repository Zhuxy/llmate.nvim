local backend = require("llmate.backend")
local n = require("nui-components")
local c = require("llmate.config")
local debug = require("llmate.debug")
local spinner_formats = require("nui-components.utils.spinner-formats")

---@class CustomModule
local M = {}

---@class ConfigSet
---@field api_key string OpenAI API key
---@field api_base string OpenAI API base URL
---@field model string Model name to use
---@field max_tokens number Maximum tokens to generate

---@class PromptSet
---@field prompt_template string Template string with placeholders
---@field prompts Prompt[] List of available prompts

---@class Prompt
---@field title string Prompt title
---@field text string Prompt content

---@class Signal
---@field user_prompt string Current user prompt text
---@field result string Current result text
---@field prompt_set PromptSet Current prompt set
---@field prompt_to_save string Title of prompt to save
---@field is_loading boolean Whether the API is loading
---@field first_loading boolean Whether this is the first loading
---@field prompt_editing boolean Whether the prompt is being edited
---@field prompt_saving boolean Whether the prompt is being saved

---Generate text using the OpenAI API
---@param config_set ConfigSet Configuration for API calls
---@param prompt_set PromptSet Prompt template and available prompts
---@param selected_text VisualSelection Selected text from editor
---@param signal Signal UI signal object for state management
---@param renderer Renderer NUI renderer instance
---@param buf number Buffer handle for output display
---@return nil
local function handle_generate(config_set, prompt_set, selected_text, signal, renderer, buf)
  if signal.is_loading:get_value() then
    vim.notify("Text generation is already in progress. Please wait.", vim.log.levels.WARN)
    debug.log("Text generation skipped - already in progress")
    return
  end

  signal.is_loading = true
  signal.first_loading = false

  local prompt_template = prompt_set.prompt_template
  local text = table.concat(selected_text.lines, "\n")
  local prompt = prompt_template:gsub("{{selected_text}}", text)
  prompt = prompt:gsub("{{user_prompt}}", signal.user_prompt:get_value())

  debug.log("Generating text with prompt: %s", prompt)
  debug.log("Selected text: %s", text)

  signal.result = ""

  vim.defer_fn(function()
    renderer:get_component_by_id("output"):focus()

    local chat_req = {
      api_key = config_set.api_key,
      api_base = config_set.api_base,
      model = config_set.model,
      max_tokens = config_set.max_tokens,
      prompt = prompt,
    }

    backend.chat_stream(chat_req, function(chunk)
      if chunk == nil or chunk == "[[DONE]]" then
        signal.is_loading = false
        signal.first_loading = false
        signal.is_cancel = false
        renderer:get_component_by_id("cancel_btn"):focus()
        return
      end

      if signal.is_cancel:get_value() then
        return
      end
      signal.result = signal.result:get_value() .. chunk

      local lines = vim.split(signal.result:get_value(), "\n", { plain = true })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end)
  end, 300)
end

---Append the result to the selected text
---@param selected_text VisualSelection Selected text from editor
---@param signal Signal UI signal object for state management
---@param renderer Renderer NUI renderer instance
---@return nil
local function handle_append(selected_text, signal, renderer)
  local lines = vim.split(signal.result:get_value(), "\n", { plain = true })
  -- add empty lines around lines
  table.insert(lines, 1, "")
  table.insert(lines, "")

  vim.api.nvim_buf_set_lines(
    selected_text.bufnum,
    selected_text.end_row,
    selected_text.end_row,
    false,
    lines
  )

  renderer:close()
end

---Replace the selected text with the result
---@param selected_text VisualSelection Selected text from editor
---@param signal Signal UI signal object for state management
---@param renderer Renderer NUI renderer instance
---@return nil
local function handle_replace(selected_text, signal, renderer)
  -- Get the text before selection in the first line
  local prefix = vim.api.nvim_buf_get_text(
    selected_text.bufnum,
    selected_text.start_row - 1,
    0,
    selected_text.start_row - 1,
    selected_text.start_col - 1,
    {}
  )[1] or ""

  -- Get the text after selection in the last line
  local suffix = vim.api.nvim_buf_get_text(
    selected_text.bufnum,
    selected_text.end_row - 1,
    selected_text.end_col,
    selected_text.end_row - 1,
    -1,
    {}
  )[1] or ""

  -- Split result into lines and handle the first/last lines
  local result_lines = vim.split(signal.result:get_value(), "\n", { plain = true, trimempty = false })
  
  -- Handle empty result
  if #result_lines == 0 then
    result_lines = {""}
  end
  
  -- Combine prefix with first line and suffix with last line
  result_lines[1] = prefix .. result_lines[1]
  result_lines[#result_lines] = result_lines[#result_lines] .. suffix

  -- Replace the entire selection with our processed lines
  vim.api.nvim_buf_set_lines(
    selected_text.bufnum,
    selected_text.start_row - 1,  -- start line (0-based)
    selected_text.end_row,        -- end line (exclusive)
    false,                        -- strict indexing
    result_lines
  )

  renderer:close()
end

---Yank the result to the system clipboard
---@param signal Signal UI signal object for state management
---@param renderer Renderer NUI renderer instance
---@return nil
local function handle_yank(signal, renderer)
  vim.fn.setreg("\"", signal.result:get_value())
  renderer:close()
end

---Open the save prompt dialog
---@param signal Signal UI signal object for state management
---@param renderer Renderer NUI renderer instance
---@return nil
local function open_save_prompt(signal, renderer)
  signal.prompt_saving = true

  vim.defer_fn(function()
    renderer:get_component_by_id("save_prompt_input"):focus()
  end, 200)
end

---Handle the save prompt submission
---@param title string Title of the prompt to save
---@param signal Signal UI signal object for state management
---@param renderer Renderer NUI renderer instance
---@param plugin_config Config Plugin configuration
---@return nil
local function handler_save_promt(title, signal, renderer, plugin_config)
  local original_title = signal.prompt_to_save:get_value()

  local prompt_set = signal.prompt_set:get_value()
  local prompts = prompt_set.prompts
  local prompt_template = prompt_set.prompt_template

  local new_prompts = {}
  local found = 0
  for i, prompt in ipairs(prompts) do
    if prompt.title == title then
      found = i
      table.insert(new_prompts, {
        title = title,
        text = signal.user_prompt:get_value(),
      })
    else
      table.insert(new_prompts, {
        title = prompt.title,
        text = prompt.text,
      })
    end
  end

  if found == 0 then
    table.insert(new_prompts, {
      title = title,
      text = signal.user_prompt:get_value(),
    })

    -- if add new prompt, it will be added to the end, so we will set signal.prompt to original
    for _, prompt in ipairs(prompts) do
      if prompt.title == original_title then
        signal.user_prompt = prompt.text
      end
    end
  end

  signal.prompt_set = {
    prompts = new_prompts,
    prompt_template = prompt_template
  }

  c.write_prompt_set(plugin_config, signal.prompt_set:get_value())

  signal.prompt_saving = false
  vim.defer_fn(function()
    renderer:get_component_by_id("user_prompt"):focus()
  end, 300)
end

---Handle the delete prompt button press
---@param signal Signal UI signal object for state management
---@param renderer Renderer NUI renderer instance
---@param plugin_config Config Plugin configuration
---@return nil
local function handle_delete_prompt(signal, renderer, plugin_config)
  local prompt_set = signal.prompt_set:get_value()
  local prompts = prompt_set.prompts

  if #prompts == 1 then
    print("cannot delete the last prompt")
    return
  end

  local title = signal.prompt_to_save:get_value()

  local prompt_template = prompt_set.prompt_template

  local new_prompts = {}
  local next_one = 0
  for i, prompt in ipairs(prompts) do
    if prompt.title ~= title then
      next_one = i
      table.insert(new_prompts, {
        title = prompt.title,
        text = prompt.text,
      })
    else
    end
  end

  -- must change the hole value of signal, then it will trigger change event
  signal.prompt_set = {
    prompts = new_prompts,
    prompt_template = prompt_template
  }

  -- after deletion, next selection will on the next one or the first one
  local total = #new_prompts
  if next_one > total then
    next_one = 1
  end

  -- update prompt_to_save
  signal.prompt_to_save = new_prompts[next_one].title
  signal.user_prompt = new_prompts[next_one].text

  c.write_prompt_set(plugin_config, signal.prompt_set:get_value())

  renderer:get_component_by_id("selection"):focus()
end

---Initialize the highlight groups for the UI
---@return nil
local function init_hightlight_group()
  -- button
  --   NuiComponentsButton
  --   NuiComponentsButtonActive
  --   NuiComponentsButtonFocus
  vim.api.nvim_set_hl(0, "NuiComponentsButton", { fg = "yellow", bold = true })

  -- select
  --   NuiComponentsSelectOption
  --   NuiComponentsSelectOptionSelected
  --   NuiComponentsSelectSeparator
  --   NuiComponentsSelectNodeFocused
  vim.api.nvim_set_hl(0, "NuiComponentsSelectNodeFocused", { fg = "yellow", bg = "gray", bold = true })

  -- spinner
  --   NuiComponentsSpinner
  vim.api.nvim_set_hl(0, "NuiComponentsSpinner", { fg = "orange" })

end

---@class Config
---@field plugin_config table Plugin configuration

---@param plugin_config Config Plugin configuration
---@param selected_text VisualSelection Selected text from editor
---@return nil
M.open_dialog = function(plugin_config, selected_text)
  debug.log("Opening dialog with config: %s", vim.inspect(plugin_config))
  init_hightlight_group()

  local config_set = c.load_config_set(plugin_config)
  local prompt_set = c.load_prompt_set(plugin_config)
  debug.log("Loaded config set: %s", vim.inspect(config_set))

  local renderer = n.create_renderer({
    position = {
      row = "5%",
      col = "50%",
    },
    width = 100,
    height = 12,
    relative = "editor",
  })

  local signal = n.create_signal({
    prompt_set = prompt_set,
    user_prompt = prompt_set.prompts[1].text,
    result = "",
    is_loading = false,
    first_loading = true,
    prompt_editing = false,
    prompt_saving = false,
    prompt_to_save = "",
    is_cancel = false,
  })

  local buf = vim.api.nvim_create_buf(false, true)

  local buf0 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf0, 0, -1, false, selected_text.lines)

  local body = function()
    return n.rows(
      n.buffer({
        id = "text",
        size = 6,
        buf = buf0,
        border_label = "📝 Selected Text",
        filetype = selected_text.filetype,
      }),
      n.select({
        id = "selection",
        size = 3,
        border_label = "🎯 Select Prompt",
        autofocus = true,
        data = signal.prompt_set:map(function(ps)
          local selection = {}
          for _, prompt in ipairs(ps.prompts) do
            table.insert(selection, n.option("⏩ " .. prompt.title, {title = prompt.title, prompt = prompt.text }))
          end
          return selection
        end),
        on_change = function(option) -- called when option is actived
          signal.user_prompt = option.prompt
          signal.prompt_to_save = option.title
        end,
        on_select = function(option) -- called when option is selected
          signal.user_prompt = option.prompt
          signal.prompt_to_save = option.title
          renderer:get_component_by_id("user_prompt"):focus()
        end,
      }),
      n.text_input({
        id = "user_prompt",
        border_label = "🎨 Edit Prompt",
        size = 4,
        value = signal.user_prompt,
        on_change = function(value)
          signal.user_prompt = value
        end,
        on_focus = function()
          signal.prompt_editing = true
        end,
        on_blur = function()
          signal.prompt_editing = false
        end,
      }),
      n.prompt({
        id = "save_prompt_input",
        prefix = " > ",
        placeholder = "Use same name to overwrite",
        border_label = {
          text = "💾 Save Prompt",
          align = "center",
        },
        hidden = signal.prompt_saving:negate(),
        on_submit = function(title)
          handler_save_promt(title, signal, renderer, plugin_config)
        end,
      }),
      n.buffer({
        id = "output",
        size = 18,
        buf = buf,
        autoscroll = true,
        filetype = "markdown",
        border_label = "🔍 Generated Result",
        is_focusable = true,
        hidden = signal.first_loading,
      }),
      n.columns(
        {
          size = 1,
          border_label = "⚡ Actions",
        },
        n.gap(2),
        n.button({
          label = "(C)ancel",
          id = "cancel_btn",
          border_style = "rounded",
          global_press_key = "<leader>c",
          on_press = function()
            renderer:close()
          end
        }),
        n.gap(2),
        n.button({
          label = "(G)enerate",
          border_style = "rounded",
          global_press_key = "<leader>g",
          on_press = function()
            handle_generate(config_set, prompt_set, selected_text, signal, renderer, buf)
          end,
        }),
        n.spinner({
          is_loading = signal.is_loading,
          hidden = signal.is_loading:negate(),
          frames = spinner_formats.box_bounce,
          padding = {
            left = 0,
            right = 0,
            top = 1,
            bottom = 1,
          }
        }),
        n.gap({
          size = 2,
          hidden = signal.is_loading,
        }),
        n.button({
          label = "(A)ppend",
          border_style = "rounded",
          global_press_key = "<leader>a",
          hidden = signal.first_loading,
          on_press = function()
            handle_append(selected_text, signal, renderer)
          end
        }),
        n.gap(2),
        n.button({
          label = "(R)eplace",
          border_style = "rounded",
          global_press_key = "<leader>r",
          hidden = signal.first_loading,
          on_press = function()
            handle_replace(selected_text, signal, renderer)
          end
        }),
        n.gap(2),
        n.button({
          label = "(Y)ank ",
          border_style = "rounded",
          global_press_key = "<leader>y",
          hidden = signal.first_loading,
          on_press = function()
            handle_yank(signal, renderer)
          end
        }),
        n.gap({
          size = 36,
          hidden = signal.first_loading:negate(),
        }),
        n.button({
          id = "delete_prompt",
          label = "(D)el prompt",
          border_style = "rounded",
          global_press_key = "<leader>d",
          hidden = signal.prompt_editing:negate(),
          on_press = function()
            handle_delete_prompt(signal, renderer, plugin_config)
          end
        }),
        n.gap(2),
        n.button({
          id = "save_prompt",
          label = "(S)ave prompt",
          border_style = "rounded",
          global_press_key = "<leader>s",
          hidden = signal.prompt_editing:negate(),
          on_press = function()
            open_save_prompt(signal, renderer)
          end
        })
      )
    )
  end

  renderer:add_mappings({
    {
      mode = { "n" },
      key = "<ESC>",
      handler = function()
        if signal.is_loading:get_value() then
          signal.is_cancel = true
          signal.is_loading = false
          vim.notify("Text generation cancelled.", vim.log.levels.WARN)
          return
        else
          renderer:close()
        end
      end,
    },
  })

  renderer:on_unmount(function()
    -- back to original window
    vim.api.nvim_set_current_win(selected_text.winid)
  end)

  renderer:render(body)

end

return M
