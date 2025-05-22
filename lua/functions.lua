function InsertTodo()
  vim.api.nvim_put({ '// todo: ' }, 'l', true, true)
end

function InsertId()
  vim.api.nvim_put({ '[Id()]' }, 'l', true, true)
end

-- Function to check uniqueness of highlighted lines in visual mode
function IsUnique()
    -- Use visual selection range regardless of mode
    local start_pos = vim.fn.getpos("'<")[2]
    local end_pos = vim.fn.getpos("'>")[2]

    -- If start_pos or end_pos is invalid, exit and prompt to select text
    if start_pos == 0 or end_pos == 0 then
        vim.api.nvim_echo({{"Please select text in visual mode.", "WarningMsg"}}, false, {})
        return
    end

    -- Collect all lines within the selected range
    local lines = vim.api.nvim_buf_get_lines(0, start_pos - 1, end_pos, false)

    -- Check for uniqueness by using a set
    local seen = {}
    for _, line in ipairs(lines) do
        if seen[line] then
            -- If duplicate is found, display message and return
            vim.api.nvim_echo({{"Selection contains duplicate lines.", "WarningMsg"}}, false, {})
            return
        end
        -- Mark line as seen
        seen[line] = true
    end

    -- If no duplicates, all lines are unique
    vim.api.nvim_echo({{"All highlighted lines are unique!", "InfoMsg"}}, false, {})
end
