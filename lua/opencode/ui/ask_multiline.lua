local M = {}

---Open a centered floating window for multiline prompt input.
---
---Keymaps:
--- - `<CR>` (insert/normal): Submit the prompt.
--- - `<C-CR>` / `<S-CR>` (insert): Insert a newline.
--- - `<Esc>` / `q` (normal): Cancel and close the window.
---
---@param default? string Text to pre-fill the input with.
---@param context opencode.Context
---@return Promise<string> input
function M.ask_multiline(default, context)
  local Promise = require("opencode.promise")

  return require("opencode.cli.server")
    .get()
    :next(function(server) ---@param server opencode.cli.server.Server
      return Promise.new(function(resolve, reject)
        local config = require("opencode.config").opts.ask_multiline

        -- Calculate centered window dimensions from config ratios
        local editor_width = vim.o.columns
        local editor_height = vim.o.lines
        local win_width = math.floor(editor_width * config.width)
        local win_height = math.floor(editor_height * config.height)
        local row = math.floor((editor_height - win_height) / 2)
        local col = math.floor((editor_width - win_width) / 2)

        -- Create a scratch buffer
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].filetype = "opencode_ask"

        -- Pre-fill default text if provided
        local default_lines = nil
        if default and default ~= "" then
          default_lines = vim.split(default, "\n", { plain = true })
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, default_lines)
        end

        -- Build footer from configured newline key
        local newline_key_label = config.newline_key
        if type(newline_key_label) == "table" then
          newline_key_label = table.concat(config.newline_key, "/")
        end
        local footer = " <CR> submit  " .. newline_key_label .. " newline  <Esc> cancel "

        -- Open the floating window
        local win = vim.api.nvim_open_win(buf, true, {
          relative = "editor",
          width = win_width,
          height = win_height,
          row = row,
          col = col,
          style = "minimal",
          border = config.border,
          title = config.title,
          title_pos = "center",
          footer = footer,
          footer_pos = "center",
        })

        -- Enable text wrapping at word boundaries
        vim.wo[win].wrap = true
        vim.wo[win].linebreak = true

        -- Start the in-process LSP for context/subagent completions
        pcall(vim.lsp.start, require("opencode.ui.ask.cmp"), { bufnr = buf })

        -- Enter insert mode, positioned after any pre-filled default text
        if default_lines then
          local last_line = #default_lines
          local last_col = #default_lines[last_line]
          vim.api.nvim_win_set_cursor(win, { last_line, last_col })
          vim.cmd("startinsert!")
        else
          vim.cmd("startinsert")
        end

        local closed = false
        local function close_win()
          if closed then
            return
          end
          closed = true
          vim.cmd("stopinsert")
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
        end

        -- Submit: gather all lines, join with newlines, resolve the promise
        local function submit()
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local text = table.concat(lines, "\n")
          close_win()
          if text == "" then
            reject()
          else
            resolve(text)
          end
        end

        -- Cancel: close the window and reject the promise
        local function cancel()
          close_win()
          context:resume()
          reject()
        end

        -- Insert a newline at the cursor position
        local function insert_newline()
          local cursor = vim.api.nvim_win_get_cursor(win)
          local line = cursor[1] - 1
          local col_pos = cursor[2]
          local current_line = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
          local before = current_line:sub(1, col_pos)
          local after = current_line:sub(col_pos + 1)
          vim.api.nvim_buf_set_lines(buf, line, line + 1, false, { before, after })
          vim.api.nvim_win_set_cursor(win, { line + 2, 0 })
        end

        -- <CR> submits in both insert and normal mode
        vim.keymap.set({ "n", "i" }, "<CR>", submit, { buffer = buf, desc = "Submit prompt" })

        -- Newline keys (configurable) — insert mode only
        local newline_keys = config.newline_key
        if type(newline_keys) == "string" then
          newline_keys = { newline_keys }
        end
        for _, key in ipairs(newline_keys) do
          vim.keymap.set("i", key, insert_newline, { buffer = buf, desc = "Insert newline" })
        end

        -- Cancel
        vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, desc = "Cancel prompt" })
        vim.keymap.set("n", "q", cancel, { buffer = buf, desc = "Cancel prompt" })

        -- Handle the buffer being closed externally (e.g., :q)
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = buf,
          once = true,
          callback = function()
            if not closed then
              closed = true
              context:resume()
              reject()
            end
          end,
        })
      end)
    end)
    :catch(function(err)
      context:resume()
      return Promise.reject(err)
    end)
end

return M
