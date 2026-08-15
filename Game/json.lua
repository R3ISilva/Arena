-- Minimal dependency-free JSON decoder.
-- Supports objects, arrays, strings (with standard escapes), numbers,
-- booleans, and null (decoded as json.null).

local json = {}

local function skipWhitespace(text, index)
    while index <= #text do
        local char = text:sub(index, index)
        if char == " " or char == "\t" or char == "\n" or char == "\r" then
            index = index + 1
        else
            break
        end
    end
    return index
end

local function codePointToUtf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40
        )
    end
    error("json.lua: unicode escape outside the basic multilingual plane is unsupported")
end

local function parseString(text, index)
    -- text[index] == '"'
    index = index + 1
    local pieces = {}
    while true do
        local char = text:sub(index, index)
        if char == "" then
            error("json.lua: unterminated string")
        elseif char == '"' then
            return table.concat(pieces), index + 1
        elseif char == "\\" then
            local escape = text:sub(index + 1, index + 1)
            local simple = {
                ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
            }
            if simple[escape] then
                pieces[#pieces + 1] = simple[escape]
                index = index + 2
            elseif escape == "u" then
                local code = tonumber(text:sub(index + 2, index + 5), 16)
                if not code then
                    error("json.lua: invalid unicode escape at position " .. index)
                end
                pieces[#pieces + 1] = codePointToUtf8(code)
                index = index + 6
            else
                error("json.lua: invalid escape sequence at position " .. index)
            end
        else
            pieces[#pieces + 1] = char
            index = index + 1
        end
    end
end

local function parseNumber(text, index)
    local cursor = index
    if text:sub(cursor, cursor) == "-" then cursor = cursor + 1 end
    while text:sub(cursor, cursor):match("%d") do cursor = cursor + 1 end
    if text:sub(cursor, cursor) == "." then
        cursor = cursor + 1
        while text:sub(cursor, cursor):match("%d") do cursor = cursor + 1 end
    end
    if text:sub(cursor, cursor) == "e" or text:sub(cursor, cursor) == "E" then
        cursor = cursor + 1
        if text:sub(cursor, cursor) == "+" or text:sub(cursor, cursor) == "-" then
            cursor = cursor + 1
        end
        while text:sub(cursor, cursor):match("%d") do cursor = cursor + 1 end
    end
    local number = tonumber(text:sub(index, cursor - 1))
    if number == nil then
        error("json.lua: invalid number at position " .. index)
    end
    return number, cursor
end

local parseValue -- forward declaration (mutual recursion with parseObject/parseArray)

local function parseObject(text, index)
    -- text[index] == "{"
    index = skipWhitespace(text, index + 1)
    local object = {}
    if text:sub(index, index) == "}" then
        return object, index + 1
    end
    while true do
        index = skipWhitespace(text, index)
        local key
        key, index = parseString(text, index)
        index = skipWhitespace(text, index)
        if text:sub(index, index) ~= ":" then
            error("json.lua: expected ':' at position " .. index)
        end
        local value
        value, index = parseValue(text, index + 1)
        object[key] = value
        index = skipWhitespace(text, index)
        local char = text:sub(index, index)
        if char == "," then
            index = index + 1
        elseif char == "}" then
            return object, index + 1
        else
            error("json.lua: expected ',' or '}' at position " .. index)
        end
    end
end

local function parseArray(text, index)
    -- text[index] == "["
    index = skipWhitespace(text, index + 1)
    local array = {}
    if text:sub(index, index) == "]" then
        return array, index + 1
    end
    while true do
        local value
        value, index = parseValue(text, index)
        array[#array + 1] = value
        index = skipWhitespace(text, index)
        local char = text:sub(index, index)
        if char == "," then
            index = index + 1
        elseif char == "]" then
            return array, index + 1
        else
            error("json.lua: expected ',' or ']' at position " .. index)
        end
    end
end

parseValue = function(text, index)
    index = skipWhitespace(text, index)
    local char = text:sub(index, index)
    if char == "{" then
        return parseObject(text, index)
    elseif char == "[" then
        return parseArray(text, index)
    elseif char == '"' then
        return parseString(text, index)
    elseif text:sub(index, index + 3) == "true" then
        return true, index + 4
    elseif text:sub(index, index + 4) == "false" then
        return false, index + 5
    elseif text:sub(index, index + 3) == "null" then
        return json.null, index + 4
    else
        return parseNumber(text, index)
    end
end

function json.decode(text)
    local value, index = parseValue(text, 1)
    index = skipWhitespace(text, index)
    if index <= #text then
        error("json.lua: unexpected trailing content at position " .. index)
    end
    return value
end

json.null = {}

return json
