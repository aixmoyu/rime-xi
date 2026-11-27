local M = {}
local MAX_LENGTH = 18
local MAX_WORD_LENGTH = 4

local function keyboard(rows, max_distance)
    local positions, neighbors = {}, {}
    for y, row in ipairs(rows) do
        local keys, offset = row[1], row[2]
        for i = 1, #keys do
            local key = keys:sub(i, i)
            positions[key] = { x = i + offset, y = y }
        end
    end
    for key, position in pairs(positions) do
        local adjacent = {}
        neighbors[key] = adjacent
        for other, point in pairs(positions) do
            local dx, dy = point.x - position.x, point.y - position.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance > 0 and distance <= max_distance then
                adjacent[#adjacent + 1] = { key = other, distance = distance }
            end
        end
    end
    return neighbors
end

local layouts = {
    qwerty = keyboard({ { "qwertyuiop", 0 }, { "asdfghjkl", 0.25 }, { "zxcvbnm", 0.75 } }, 1.25),
    t9 = keyboard({ { "23", 1 }, { "456", 0 }, { "789", 0 } }, 1),
}

local function read_trie(path, layout)
    local file = io.open(path, "rb")
    if not file then return nil end
    local magic = file:read("*l")
    local data = file:read("*a")
    file:close()
    if magic == "RIME-KEY-TRIE-1\t" .. layout and #data >= 9 and #data % 6 == 3 then
        return data
    end
end

local function first_child(data, node)
    local offset = node * 6 + 1
    local a, b, c = data:byte(offset, offset + 2)
    return a + 256 * (b + 256 * c)
end

local function child(data, node, key)
    if not node then return nil end
    local first, stop = first_child(data, node), first_child(data, node + 1)
    for next_node = first, stop - 1 do
        local letter = data:byte(next_node * 6 + 4)
        if letter == key then return next_node end
        if letter > key then return nil end
    end
end

local function ranked_codes(data, input, neighbors, first, min_gain, exact_min_gain)
    local path = { [0] = 0 }
    for i = 1, #input do
        path[i] = child(data, path[i - 1], input:byte(i))
    end
    local original = path[#input]
    local exact = original and data:byte(original * 6 + 6) or 0
    local baseline = original and data:byte(original * 6 + 5) or 0
    if exact > 0 then
        baseline, min_gain = exact, exact_min_gain
    end

    local matches = {}
    for i = first, #input do
        if not path[i - 1] then break end
        local typed = path[i]
        local typed_weight = typed and data:byte(typed * 6 + 5) or 0
        for _, adjacent in ipairs(neighbors[input:sub(i, i)]) do
            local node = child(data, path[i - 1], adjacent.key:byte())
            -- Both next-key probabilities share the same parent denominator.
            local key_gain = node and data:byte(node * 6 + 5) - typed_weight
            for j = i + 1, #input do
                if not node then break end
                node = child(data, node, input:byte(j))
            end
            if node then
                local terminal = data:byte(node * 6 + 6)
                local score = terminal - 16 * (adjacent.distance - 1)
                if terminal > 0 and (baseline == 0 or score >= baseline + min_gain) then
                    matches[#matches + 1] = {
                        code = input:sub(1, i - 1) .. adjacent.key .. input:sub(i + 1),
                        score = score,
                        key_gain = key_gain,
                    }
                end
            end
        end
    end
    table.sort(matches, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.key_gain ~= b.key_gain then return a.key_gain > b.key_gain end
        return a.code < b.code
    end)
    return matches, original ~= nil, exact > 0
end

local accents, digits = {}, {}
local utf8_char = "[%z\1-\127\194-\244][\128-\191]*"
for plain, variants in pairs({
    a = "āáǎà", o = "ōóǒò", e = "ēéěè", i = "īíǐì", u = "ūúǔù",
    v = "ǖǘǚǜü", n = "ńňǹ", m = "ḿ",
}) do
    for variant in variants:gmatch(utf8_char) do accents[variant] = plain end
end
local t9_digits = "22233344455566677778889999"
for i = 1, #t9_digits do
    digits[string.char(96 + i)] = t9_digits:sub(i, i)
end

local function canonical_spelling(comment, layout)
    local syllables = {}
    for syllable in comment:gmatch("%S+") do
        local plain = syllable:match("^[^;]+")
        if not plain then return nil end
        plain = plain:gsub("̀", ""):gsub(utf8_char, accents)
        if not plain:match("^[a-z]+$") then return nil end
        if plain == "ng" then plain = "eng" end
        if layout == "t9" then
            if plain == "m" then plain = "me" end
            if plain == "n" then plain = "en" end
        end
        syllables[#syllables + 1] = plain
    end
    local pinyin = table.concat(syllables, " ")
    local code = table.concat(syllables)
    if layout == "t9" then code = code:gsub(".", digits) end
    return code, pinyin
end

local function exact_candidates(translator, code, seg, layout, limit, word_limit)
    local results = {}
    local translation = translator:query(code, seg)
    if not translation then return results end
    local inspected = 0
    for candidate in translation:iter() do
        if candidate._end < seg._end or inspected >= 8 then break end
        inspected = inspected + 1
        if candidate.type == "phrase" and candidate.start == seg.start and candidate._end == seg._end then
            local canonical, pinyin = canonical_spelling(candidate.comment, layout)
            if canonical == code and (not word_limit or select(2, candidate.text:gsub(utf8_char, "")) <= word_limit) then
                results[#results + 1] = { text = candidate.text, pinyin = pinyin }
                if #results >= limit then break end
            end
        end
    end
    return results
end

function M.init(env)
    local config = env.engine.schema.config
    env.layout = config:get_string("key_correction/layout")
    env.enabled = layouts[env.layout] ~= nil and config:get_bool("key_correction/enabled") ~= false
    env.first = config:get_bool("key_correction/protect_first") == false and 1 or 2
    env.min_length = math.max(4, config:get_int("key_correction/min_length") or 4)
    env.max_lookups = math.max(1, math.min(8, config:get_int("key_correction/max_lookups") or 3))
    env.min_gain = 8 * math.log(math.max(1, config:get_int("key_correction/min_gain") or 3))
    env.exact_min_gain = 8 * math.log(math.max(1, config:get_int("key_correction/exact_min_gain") or 12))
    env.limit = math.max(1, math.min(8, config:get_int("key_correction/max_candidates") or 4))
end

function M.func(input, seg, env)
    if not env.enabled or #input < env.min_length or #input > MAX_LENGTH or not seg:has_tag("abc") then
        return
    end
    local context = env.engine.context
    if context:get_option("ascii_mode") or seg._end ~= #context.input then return end
    local pattern = env.layout == "t9" and "^[2-9]+$" or "^[a-z]+$"
    if not input:match(pattern) then return end

    if env.trie == nil then
        local path = rime_api.get_user_data_dir() .. "/lua/key_correction_data/" .. env.layout .. ".bin"
        env.trie = read_trie(path, env.layout) or false
        if not env.trie then log.warning("key_correction: missing or invalid trie " .. path) end
    end
    if not env.trie then return end
    local matches, valid_prefix, known_exact = ranked_codes(
        env.trie, input, layouts[env.layout], env.first, env.min_gain, env.exact_min_gain)
    if #matches == 0 then return end

    if env.translator == nil then
        env.translator = Component and Component.Translator
            and Component.Translator(env.engine, "key_correction_lookup", "script_translator") or false
        if not env.translator then log.warning("key_correction: script translator lookup unavailable") end
    end
    if not env.translator then return end
    if not known_exact and #exact_candidates(env.translator, input, seg, env.layout, 1) > 0 then return end

    local max_lookups = valid_prefix and 1 or env.max_lookups
    local limit = valid_prefix and 1 or env.limit
    local seen, emitted = {}, 0
    for rank = 1, math.min(max_lookups, #matches) do
        local code = matches[rank].code
        for _, match in ipairs(exact_candidates(env.translator, code, seg, env.layout, limit, MAX_WORD_LENGTH)) do
            if not seen[match.text] then
                seen[match.text] = true
                emitted = emitted + 1
                -- YuanShu's T9 uses the comment as pinyin for the preedit.
                local candidate = Candidate("key_correction", seg.start, seg._end, match.text, match.pinyin)
                candidate.preedit = input
                candidate.quality = -1 - emitted / 10
                yield(candidate)
                if emitted >= limit then return end
            end
        end
    end
end

return M
