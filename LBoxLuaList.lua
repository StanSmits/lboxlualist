--[[
    Lmaobox Lua List
    Version: 1.0
    Author: StanSmits
    Description: A script that fetches a list of Lua scripts from a remote server and allows you to inject them into the game.


    Dependencies:
    - json decoder by rxi (https://github.com/rxi/json.lua)
]]


--
-- Copyright (c) 2020 rxi
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--
-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local parse

local function create_set(...)
  local res = {}
  for i = 1, select("#", ...) do
    res[ select(i, ...) ] = true
  end
  return res
end

local space_chars   = create_set(" ", "\t", "\r", "\n")
local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local literals      = create_set("true", "false", "null")

local literal_map = {
  [ "true"  ] = true,
  [ "false" ] = false,
  [ "null"  ] = nil,
}


local function next_char(str, idx, set, negate)
  for i = idx, #str do
    if set[str:sub(i, i)] ~= negate then
      return i
    end
  end
  return #str + 1
end


local function decode_error(str, idx, msg)
  local line_count = 1
  local col_count = 1
  for i = 1, idx - 1 do
    col_count = col_count + 1
    if str:sub(i, i) == "\n" then
      line_count = line_count + 1
      col_count = 1
    end
  end
  error( string.format("%s at line %d col %d", msg, line_count, col_count) )
end


local function codepoint_to_utf8(n)
  -- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
  local f = math.floor
  if n <= 0x7f then
    return string.char(n)
  elseif n <= 0x7ff then
    return string.char(f(n / 64) + 192, n % 64 + 128)
  elseif n <= 0xffff then
    return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
  elseif n <= 0x10ffff then
    return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
                       f(n % 4096 / 64) + 128, n % 64 + 128)
  end
  error( string.format("invalid unicode codepoint '%x'", n) )
end


local function parse_unicode_escape(s)
  local n1 = tonumber( s:sub(1, 4),  16 )
  local n2 = tonumber( s:sub(7, 10), 16 )
   -- Surrogate pair?
  if n2 then
    return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
  else
    return codepoint_to_utf8(n1)
  end
end


local function parse_string(str, i)
  local res = ""
  local j = i + 1
  local k = j

  while j <= #str do
    local x = str:byte(j)

    if x < 32 then
      decode_error(str, j, "control character in string")

    elseif x == 92 then -- `\`: Escape
      res = res .. str:sub(k, j - 1)
      j = j + 1
      local c = str:sub(j, j)
      if c == "u" then
        local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
                 or str:match("^%x%x%x%x", j + 1)
                 or decode_error(str, j - 1, "invalid unicode escape in string")
        res = res .. parse_unicode_escape(hex)
        j = j + #hex
      else
        if not escape_chars[c] then
          decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
        end
        res = res .. escape_char_map_inv[c]
      end
      k = j + 1

    elseif x == 34 then -- `"`: End of string
      res = res .. str:sub(k, j - 1)
      return res, j + 1
    end

    j = j + 1
  end

  decode_error(str, i, "expected closing quote for string")
end


local function parse_number(str, i)
  local x = next_char(str, i, delim_chars)
  local s = str:sub(i, x - 1)
  local n = tonumber(s)
  if not n then
    decode_error(str, i, "invalid number '" .. s .. "'")
  end
  return n, x
end


local function parse_literal(str, i)
  local x = next_char(str, i, delim_chars)
  local word = str:sub(i, x - 1)
  if not literals[word] then
    decode_error(str, i, "invalid literal '" .. word .. "'")
  end
  return literal_map[word], x
end


local function parse_array(str, i)
  local res = {}
  local n = 1
  i = i + 1
  while 1 do
    local x
    i = next_char(str, i, space_chars, true)
    -- Empty / end of array?
    if str:sub(i, i) == "]" then
      i = i + 1
      break
    end
    -- Read token
    x, i = parse(str, i)
    res[n] = x
    n = n + 1
    -- Next token
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "]" then break end
    if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
  end
  return res, i
end


local function parse_object(str, i)
  local res = {}
  i = i + 1
  while 1 do
    local key, val
    i = next_char(str, i, space_chars, true)
    -- Empty / end of object?
    if str:sub(i, i) == "}" then
      i = i + 1
      break
    end
    -- Read key
    if str:sub(i, i) ~= '"' then
      decode_error(str, i, "expected string for key")
    end
    key, i = parse(str, i)
    -- Read ':' delimiter
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) ~= ":" then
      decode_error(str, i, "expected ':' after key")
    end
    i = next_char(str, i + 1, space_chars, true)
    -- Read value
    val, i = parse(str, i)
    -- Set
    res[key] = val
    -- Next token
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "}" then break end
    if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
  end
  return res, i
end


local char_func_map = {
  [ '"' ] = parse_string,
  [ "0" ] = parse_number,
  [ "1" ] = parse_number,
  [ "2" ] = parse_number,
  [ "3" ] = parse_number,
  [ "4" ] = parse_number,
  [ "5" ] = parse_number,
  [ "6" ] = parse_number,
  [ "7" ] = parse_number,
  [ "8" ] = parse_number,
  [ "9" ] = parse_number,
  [ "-" ] = parse_number,
  [ "t" ] = parse_literal,
  [ "f" ] = parse_literal,
  [ "n" ] = parse_literal,
  [ "[" ] = parse_array,
  [ "{" ] = parse_object,
}


parse = function(str, idx)
  local chr = str:sub(idx, idx)
  local f = char_func_map[chr]
  if f then
    return f(str, idx)
  end
  decode_error(str, idx, "unexpected character '" .. chr .. "'")
end


function decodeJson(str)
  if type(str) ~= "string" then
    error("expected argument of type string, got " .. type(str))
  end
  local res, idx = parse(str, next_char(str, 1, space_chars, true))
  idx = next_char(str, idx, space_chars, true)
  if idx <= #str then
    decode_error(str, idx, "trailing garbage")
  end
  return res
end

--[[

    ** END OF JSON LIBRARY **

]]--

local scriptContent = http.Get("https://raw.githubusercontent.com/StanSmits/lboxlualist/refs/heads/master/list.json")
local fullLuaList = nil


if scriptContent then
    local success, luaList = pcall(function()
        return decodeJson(scriptContent)
    end)

    if success and type(luaList) == "table" then
        printc(123, 75, 191, 255, "Welcome to Lmaobox Lua List")
        printc(123, 75, 191, 255, "Type 'help' for a list of commands.")
        printc(123, 75, 191, 255, "-------------------------------------------------------------------------------")
        printc(199, 170, 255, 255, "Available Lua scripts:")
        for index, luaInfo in ipairs(luaList) do
            print(string.format("[%d] %s - %s", index, luaInfo.name, luaInfo.description))
        end

        fullLuaList = luaList

        function InjectLua(index)
            local luaInfo = luaList[index]
            if luaInfo then
                local luaContent = http.Get(luaInfo.url)
                if luaContent then
                    local chunk, errorMsg = load(luaContent)
                    if chunk then
                        chunk()
                        printc(23, 255, 23, 255, string.format("Injected: %s - %s", luaInfo.name, luaInfo.description))
                    else
                        printc(255, 23, 23, 255, "Error loading Lua: " .. errorMsg)
                    end
                else
                    printc(255, 23, 23, 255, "Failed to fetch Lua script from URL.")
                end
            else
                printc(255, 23, 23, 255, "Invalid Lua index.")
            end
        end

        printc(199, 170, 255, 255, "Type 'inject <number>' in the console to load a Lua script.")
    else
        printc(255, 23, 23, 255, "Failed to decode JSON. Error: " .. tostring(luaList))
    end
else
    printc(255, 23, 23, 255, "Failed to fetch Lua list from the server.")
end

function runHelp()
    printc(175, 154, 219, 255, "Available commands:")
    printc(175, 154, 219, 255, "list - List all available Lua scripts.")
    printc(175, 154, 219, 255, "inject <number> - Inject a Lua script.")
    printc(175, 154, 219, 255, "download <number> - Shows url of a Lua script.")
    printc(175, 154, 219, 255, "search <query> - Search for Lua scripts.")
end



callbacks.Register("SendStringCmd", function(cmd)
    command = cmd:Get()

    local args = {}
    for word in command:gmatch("%S+") do
        table.insert(args, word)
    end

    if args[1] == "inject" then
        local index = tonumber(args[2])

        if not index then
            printc(255, 23, 23, 255, "Invalid Lua index.")
            return
        end

        InjectLua(index)
    end

    -- Search functionality
    if args[1] == "search" then
        local search = args[2]
        if not search then
            printc(255, 23, 23, 255, "Invalid search query.")
            return
        end
        local found = false
        if fullLuaList then
            for index, luaInfo in ipairs(fullLuaList) do
                if string.find(string.lower(luaInfo.name), string.lower(search)) or string.find(string.lower(luaInfo.description), string.lower(search)) then
                    print(string.format("[%d] %s - %s", index, luaInfo.name, luaInfo.description))
                    found = true
                end
            end
        else
            printc(255, 23, 23, 255, "Lua list is not available.")
        end

        if not found then
            printc(255, 23, 23, 255, "No results found.")
        end
    end

    -- Download command
    if args[1] == "download" then
        local index = tonumber(args[2])

        if not index then
            printc(255, 23, 23, 255, "Invalid Lua index.")
            return
        end

        local luaInfo = fullLuaList[index]
        if luaInfo then
            print(string.format("%s - %s", luaInfo.name, luaInfo.url))
        else
            printc(255, 23, 23, 255, "Invalid Lua index.")
        end
    end

    -- List command
    if args[1] == "list" then
        printc(199, 170, 255, 255, "Available Lua scripts:")
        for index, luaInfo in ipairs(fullLuaList) do
            print(string.format("[%d] %s - %s", index, luaInfo.name, luaInfo.description))
        end
    end

    -- Help command
    if args[1] == "help" then
        runHelp()
    end
end)