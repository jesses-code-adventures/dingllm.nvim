require("curl_args")
require("data_handlers")
require("models")
require("files")
require("windows")
require("settings")
require("prompt")
require("utils")
local Job = require 'plenary.job'

local ns_id = vim.api.nvim_create_namespace('dingllm')
local group = vim.api.nvim_create_augroup('LLM_AutoGroup', { clear = true })
local active_job = nil

local M = {
  _reasoning_win = nil,
  _reasoning_buf = nil,
  _settings_win = nil,
  _settings_buf = nil,
}

local function validate_model(model, available, fail_msg)
  for _, m in ipairs(available) do
    if m == model then
      return true
    end
  end
  vim.notify(fail_msg, vim.log.levels.WARN)
  return false
end

function M._update_settings(settings)
  if not settings then return end
  M.show_reasoning = settings.show_reasoning
  M.model = settings.model
  M._validate_settings()
end

function M._validate_settings()
  local available = Available_models(M.excluded_providers)

  local default_fail_msg = "default model isn't provided, it may not exist or you may have the provider excluded. available models: " .. vim.inspect(available) .. ", default model: " .. M.default_model
  validate_model(M.default_model, available, default_fail_msg)

  if not M.model or M.model == "" then return end

  local model_fail_msg = "selected model isn't provided, it may not exist or you may have the provider excluded. available models: " .. vim.inspect(available) .. ", selected model: " .. M.model
  validate_model(M.model, available, model_fail_msg)
end

function M.setup(opts)
  M._storage_dir = opts.storage_dir or vim.fn.stdpath('data') .. '/llm'
  M.excluded_providers = opts.excluded_providers or {}
  M.llmfiles_name = opts.llmfiles_name or '.llmfiles'
  M.chat_name = opts.chat_name or 'chat.md'
  M.default_model = opts.default_model or 'anthropic-claude-3-5-sonnet-20241022'
  M.help_prompt = opts.help_prompt
  M.replace_prompt = opts.replace_prompt

  local settings = Get_settings(M._storage_dir)
  if settings then
    M._update_settings(settings)
  else
    M.show_reasoning = false
    M.model = M.default_model
  end
end

function M._reasoning_bufwin_fn(f)
  local bufwin = f()
  M._reasoning_buf, M._reasoning_win = bufwin[1], bufwin[2]
end

function M._settings_bufwin_fn(f)
  local bufwin = f()
  M._settings_buf, M._settings_win = bufwin[1], bufwin[2]
end

local function parse_and_handle_data(line, curr_event_state, handle_data_fn, opts, extmark_id)
  local event = line:match('^event: (.+)$')
  if event then
    return event
  end

  local data = line:match('^data: (.+)$') or (String_startswith(Strip_string(line), '"text": "') and Strip_string(line))
  if data then
    handle_data_fn(data, curr_event_state, opts.show_reasoning,
      function(s) Write_string_at_extmark(s, extmark_id, ns_id) end,
      function(s) Write_floating_content(s, M._reasoning_buf, M._reasoning_win) end)
  end
  return curr_event_state
end

function M._request_and_stream(opts, system_prompt)
  local prompt = Get_prompt(opts)
  local handle_data_fn = Get_data_fn(opts.model)
  local args = Make_curl_args(opts.model)(opts, prompt, system_prompt)
  local curr_event_state = nil

  local crow = unpack(vim.api.nvim_win_get_cursor(0))
  local extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, crow - 1, -1, {})

  if active_job then
    active_job:shutdown()
    active_job = nil
    M._reasoning_bufwin_fn(Clear_floating_display())
  end

---@diagnostic disable-next-line: missing-fields
  active_job = Job:new({
    command = 'curl',
    args = args,
    on_stdout = function(_, out)
      curr_event_state = parse_and_handle_data(out, curr_event_state, handle_data_fn, opts, extmark_id)
    end,
    on_stderr = function(_, err)
      if err and err ~= "" then
        vim.schedule(function()
          vim.notify("stderr: " .. err, vim.log.levels.ERROR)
        end)
      end
    end,
    on_exit = function(j, return_val)
      active_job = nil
      if return_val ~= 0 then
        vim.schedule(function()
          vim.notify("Job failed with exit code " .. return_val .. "\nstdout:\n" ..
            table.concat(j:result(), "\n") .. "\nstderr:\n" .. table.concat(j:stderr_result(), "\n"),
            vim.log.levels.ERROR)
        end)
      end
    end
  }):start()

  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'LLM_Escape',
    callback = function()
      if active_job then
        active_job:shutdown()
        LlmAppPrint('streaming cancelled')
        active_job = nil
      end
      M._reasoning_bufwin_fn(Clear_floating_display)
    end,
  })

  vim.keymap.set('n', '<Esc>', ':doautocmd User LLM_Escape<CR>', { noremap = true, silent = true })
  return active_job
end

function M._handle_prompt(help)
  if not M.model then
    M._update_settings({ model = M.default_model, show_reasoning = false })
  end

  local system_prompt = Get_system_prompt(M.help_prompt, M.replace_prompt, M._storage_dir, M.llmfiles_name, not help)
  local opts = Get_opts(M.model, system_prompt, help, M.show_reasoning)

  if opts.show_reasoning and (M._reasoning_buf or M._reasoning_win) then
    M._reasoning_bufwin_fn(Clear_floating_display)
  end

  vim.api.nvim_clear_autocmds({ group = group })
  M._request_and_stream(opts, system_prompt)
  
  if opts.show_reasoning then
    M._reasoning_bufwin_fn(function() return Open_reasoning_window(M._reasoning_buf, M._reasoning_win) end)
  end
end

function M._select_model_fn(selected_model)
  M.model = selected_model or Available_models(M.excluded_providers)[vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]]
  LlmAppPrint("set model to [" .. M.model .. "]")
  M._update_settings(Write_selected_model(M._storage_dir, M.model, M.show_reasoning))
end

function M._toggle_reasoning_window_fn()
  M._update_settings(Write_selected_model(M._storage_dir, M.model, not M.show_reasoning))
end

function M.replace()
  M._handle_prompt(false)
end

function M.help()
  M._handle_prompt(true)
end

function M.models()
  if M._settings_win and not vim.api.nvim_win_is_valid(M._settings_win) then
    M._settings_win = nil
  end
  if M._settings_buf and not vim.api.nvim_buf_is_valid(M._settings_buf) then
    M._settings_buf = nil
  end
  M._settings_bufwin_fn(function() 
    return Select_model(M._settings_buf, M._settings_win, Available_models(M.excluded_providers),
      M._select_model_fn, M._toggle_reasoning_window_fn)
  end)
end

function M.chat()
  vim.cmd([[
    vsplit
    wincmd l
    vertical resize 60
    e ]] .. Get_hashed_project_path(M._storage_dir, M.chat_name) .. [[
    set wrap
    split
    resize 5
    e ]] .. Get_hashed_project_path(M._storage_dir, M.llmfiles_name))
end

return M
