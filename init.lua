-- Copyright 2018 Alexander Misel. See LICENSE.

local M = {}

-- Sets default buffer properties for JavaScript files.
events.connect(events.LEXER_LOADED, function(lang)
  if lang == 'javascript' then
    buffer.use_tabs = false
    buffer.tab_width = 2
  end
end)

-- Autocompletion and documentation.
---
-- List of ctags files to use for autocompletion.
-- @class table
-- @name tags
M.tags = {_HOME..'/modules/js/tags', _USERHOME..'/modules/js/tags'}
---
-- Map of expression patterns to their types.
-- Expressions are expected to match after the '=' sign of a statement.
-- @class table
-- @name expr_types
M.expr_types = {
  ['^[\'"`]'] = 'String',
  ['^%['] = 'Array',
  ['^{'] = 'Object',
  ['^function'] = 'Function',
  ['^/'] = 'RegExp',
  ['^%$%(.-%)'] = 'jQuery'
}

M.symbol_subst = {
  ['^[\'"].*[\'"]$'] = 'String',
  ['^%[.*%]$'] = 'Array',
  ['^/.*/[gimuy]*$'] = 'RegExp',
  ['^localStorage$'] = 'Storage',
  ['^sessionStorage$'] = 'Storage',
  ['^%$'] = 'jQuery'
}

local XPM = textadept.editing.XPM_IMAGES
local xpms = {
  c = XPM.CLASS, m = XPM.METHOD, f = XPM.VARIABLE
}

textadept.editing.autocompleters.javascript = function()
  local list = {}
  -- Retrieve the symbol behind the caret.
  local line, pos = buffer:get_cur_line()
  
  local symbol = ''
  local rawsymbol, op, part = line:sub(1, pos):match('([%w_%$#%.%-=\'"%[%]/%(%)]-)(%.?)([%w_%$]*)$')
  -- identify literals like "'foo'." and "[1, 2, 3].".
  rawsymbol = rawsymbol:gsub('^window%.', '')
  if rawsymbol then
    for patt, type in pairs(M.symbol_subst) do
      if rawsymbol:find(patt) then
        symbol = type
        break
      end
    end
  elseif part == '' then
    return nil -- nothing to complete
  end
  
  -- Attempt to identify the symbol type.
  if rawsymbol and symbol == '' then
    symbol = rawsymbol:match('([%w_%$%.]*)$')
    if symbol == '' and part == '' then return nil end -- nothing to complete
    
    if symbol ~= '' then
      local buffer = buffer
      local assignment = symbol:gsub('(%p)', '%%%1')..'%s*=%s*(.*)$'
      for i = buffer:line_from_position(buffer.current_pos) - 1, 0, -1 do
        local expr = buffer:get_line(i):match(assignment)
        if expr then
          for patt, type in pairs(M.expr_types) do
            if expr:find(patt) then symbol = type break end
          end
          if expr:find('^new%s+[%w_.]+%s*%b()%s*$') then
            symbol = expr:match('^new%s+([%w_.]+)%s*%b()%s*$') -- e.g. a = new Foo()
            break
          end
        end
      end
    end
  end
  -- Search through ctags for completions for that symbol.
  local name_patt = '^'..part
  local sep = string.char(buffer.auto_c_type_separator)
  for i = 1, #M.tags do
    if lfs.attributes(M.tags[i]) then
      local hasFound = false
      for line in io.lines(M.tags[i]) do
        local name = line:match('^%S+')
        if not name:find(name_patt) then
          if hasFound then break end
        elseif not list[name] then
          hasFound = true
          local fields = line:match(';"\t(.*)$')
          local k, class = fields:sub(1, 1), fields:match('class:(%S+)') or ''
          if class == symbol or (op == '' and class == 'window')
                             or (op == '.' and class == 'Object' and symbol ~= 'jQuery') then
            list[#list + 1] = string.format('%s%s%d', name, sep, xpms[k])
            list[name] = true
          end
        end
      end
    end
  end
  return #part, list
end

-- Snippets.

if type(snippets) == 'table' then
---
-- Table of JS-specific snippets.
-- @class table
-- @name _G.snippets.javascript
  snippets.javascript = {
    ['do'] = 'do {\n\t%0\n} while (%1)',
    ['if'] = 'if (%1) {\n\t%0\n}',
    eif = 'else if (%1) {\n\t%0\n}',
    ['else'] = 'else {\n\t%0\n}',
    interval = 'setInterval(%0(function), %1(delay))',
    timeout = 'setTimeout(%0(function), %1(delay))',
    ['for'] = 'for (%1; %2; %3) {\n\t%0\n}',
    fori = 'for (%1 in %2) {\n\t%0\n}',
    ['while'] = 'while (%1) {\n\t%0\n}',
    try = 'try {\n\t%1\n} catch (%2(e)) {\n\t%3\n}',
    ['/*'] = '/**\n * %0\n */',
    log = 'console.log(%1)',
    func = 'function %1(name) (%2) {\n\t%0\n}',
    afunc = 'function (%1) {\n\t%0\n}'
  }
end

return M
