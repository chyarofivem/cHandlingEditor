--[[
    cHandlingEditor server/client contract

    server -> client  cHandlingEditor:client:requestVehicle { requestId }
    client -> server  cHandlingEditor:server:inspectVehicle {
        requestId, modelHash, modelName?, displayName?, plate?, error?
    }
    server -> client  cHandlingEditor:client:open {
        sessionId, canEdit,
        vehicle = { modelHash, modelName, displayName },
        handling = { name, resource, path },
        groups = {
            { name, label, fields = {
                { id, name, label, class, type, value, originalValue,
                  live, restartRequired }
            }}
        }
    }
    client -> server  cHandlingEditor:server:saveField {
        requestId, sessionId, fieldId, value, expectedValue
    }
    server -> client  cHandlingEditor:client:saveResult {
        requestId, fieldId, ok, value?, error?, conflict?, restartRequired?
    }
    client -> server  cHandlingEditor:server:closeSession { sessionId }
    client -> server  cHandlingEditor:server:restartResource { requestId, sessionId }
    server -> client  cHandlingEditor:client:restartResult {
        requestId, ok, resource?, message?, error?
    }
    server -> client  cHandlingEditor:client:notify { message, type }

    Resource names, file paths, handling names, XML offsets, and field locators are
    never accepted from a client. They are resolved from active resource metadata
    and retained only in short-lived, server-owned sessions.
]]

local RESOURCE_NAME = GetCurrentResourceName()
local EVENT_PREFIX = 'cHandlingEditor'
local VIEW_ACE = 'chandlingeditor.view'
local EDIT_ACE = 'chandlingeditor.edit'
local ADMIN_COMPAT_ACE = 'admin'

local UINT32 = 4294967296
local UINT32_MASK = 0xFFFFFFFF
local MAX_XML_BYTES = 16 * 1024 * 1024
local MAX_RESOURCE_FILES = 25000
local MAX_DIRECTORY_DEPTH = 32
local MAX_FIELDS = 2000
local REQUEST_TTL_SECONDS = 20
local SESSION_TTL_SECONDS = 30 * 60
local RESTART_PROPERTY_TIMEOUT_MS = 2500
local RESTART_DELETE_RETRY_MS = 125
local RESTART_DELETE_ATTEMPTS = 32
local RESTART_EMPTY_CONFIRMATIONS = 3
local RESTART_EMPTY_SETTLE_MS = 400
local RESTART_START_TIMEOUT_MS = 12000
local RESTART_COMMAND_TIMEOUT_MS = 3500
local RESTART_SPAWN_TIMEOUT_MS = 5000
local RESTART_POST_START_SETTLE_MS = 1500
local RESTART_MODEL_READY_TIMEOUT_MS = 12000
local RESTART_PROPERTY_APPLY_TIMEOUT_MS = 4500
local RESTART_SPAWN_STAGGER_MS = 250

local activeIndex = {
    ready = false,
    generation = 0,
    models = {},
    unresolvedModels = {},
    resources = {},
    modelCount = 0,
    handlingCount = 0,
}

local pendingInspections = {}
local pendingVanillaCaptures = {}
local sessions = {}
local fileQueues = {}
local resourceRestarts = {}
local scanRunning = false
local scanAgain = false
local scanTimerPending = false
local tokenCounter = 0

local function log(message)
    print(('[%s] %s'):format(RESOURCE_NAME, tostring(message)))
end

-- Depending on the FXServer/Lua runtime, ACE natives can return numeric 1/0
-- instead of Lua booleans. Normalize at the boundary: 0 is truthy in Lua, and
-- sending 1 to the client is later rejected by its strict boolean check.
local function aceResultAllowed(result)
    return result == true or result == 1
end

local function isPlayerAceAllowed(playerSource, ace)
    return aceResultAllowed(IsPlayerAceAllowed(playerSource, ace))
end

-- Qbox's established group.admin convention grants the narrow `admin` ACE
-- (permissions.cfg does this explicitly). Keep the editor-specific ACEs as the
-- public controls for standalone and view-only roles, while treating that
-- existing admin ACE as a compatibility grant for actual server admins.
local function canPlayerView(playerSource)
    return isPlayerAceAllowed(playerSource, VIEW_ACE)
        or isPlayerAceAllowed(playerSource, ADMIN_COMPAT_ACE)
end

local function canPlayerEdit(playerSource)
    return isPlayerAceAllowed(playerSource, EDIT_ACE)
        or isPlayerAceAllowed(playerSource, ADMIN_COMPAT_ACE)
end

local function auditAdminAceConfiguration()
    if type(IsPrincipalAceAllowed) ~= 'function' then
        log(('ACE audit unavailable. In the FXServer console run: test_ace group.admin %s')
            :format(EDIT_ACE))
        return
    end

    local viewOk, adminCanView = pcall(IsPrincipalAceAllowed, 'group.admin', VIEW_ACE)
    local editOk, adminCanEdit = pcall(IsPrincipalAceAllowed, 'group.admin', EDIT_ACE)
    local compatOk, adminCompatibility = pcall(IsPrincipalAceAllowed, 'group.admin', ADMIN_COMPAT_ACE)
    adminCanView = viewOk and aceResultAllowed(adminCanView) or false
    adminCanEdit = editOk and aceResultAllowed(adminCanEdit) or false
    adminCompatibility = compatOk and aceResultAllowed(adminCompatibility) or false
    local effectiveView = adminCanView or adminCompatibility
    local effectiveEdit = adminCanEdit or adminCompatibility
    if effectiveView and effectiveEdit then
        log(('ACE audit: group.admin can view/edit (dedicated view=%s, dedicated edit=%s, admin compatibility=%s).')
            :format(tostring(adminCanView), tostring(adminCanEdit), tostring(adminCompatibility)))
        return
    end

    log(('ACE WARNING: group.admin does not currently resolve editor access (view=%s, edit=%s, admin compatibility=%s). '
        .. 'Run `exec permissions.cfg`, then verify with `test_ace group.admin %s` and `test_ace group.admin %s`. '
        .. 'Restarting only the resource does not reload cfg files.')
        :format(tostring(adminCanView), tostring(adminCanEdit), tostring(adminCompatibility),
            EDIT_ACE, ADMIN_COMPAT_ACE))
end

local function trim(value)
    if type(value) ~= 'string' then
        return ''
    end
    return value:match('^%s*(.-)%s*$') or ''
end

local function finiteNumber(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function copyValue(value)
    if type(value) ~= 'table' then
        return value
    end

    local copied = {}
    for key, child in pairs(value) do
        copied[key] = copyValue(child)
    end
    return copied
end

local function nowSeconds()
    return os.time()
end

local function newToken(prefix)
    tokenCounter = tokenCounter + 1
    local timer = type(GetGameTimer) == 'function' and GetGameTimer() or 0
    local randomA = math.random(0, 0x7FFFFFFF)
    local randomB = math.random(0, 0x7FFFFFFF)
    return ('%s_%x_%x_%x_%x'):format(prefix, nowSeconds(), timer, tokenCounter, randomA ~ randomB)
end

local function normalizeHash(value)
    local numberValue = tonumber(value)
    if not finiteNumber(numberValue) then
        return nil
    end

    numberValue = math.floor(numberValue) % UINT32
    if numberValue < 0 then
        numberValue = numberValue + UINT32
    end
    return numberValue
end

-- Jenkins one-at-a-time, matching GTA/FiveM joaat for ASCII model names.
local function joaat(value)
    local hash = 0
    value = string.lower(tostring(value or ''))

    for index = 1, #value do
        hash = (hash + value:byte(index)) & UINT32_MASK
        hash = (hash + ((hash << 10) & UINT32_MASK)) & UINT32_MASK
        hash = (hash ~ (hash >> 6)) & UINT32_MASK
    end

    hash = (hash + ((hash << 3) & UINT32_MASK)) & UINT32_MASK
    hash = (hash ~ (hash >> 11)) & UINT32_MASK
    hash = (hash + ((hash << 15) & UINT32_MASK)) & UINT32_MASK
    return hash
end

local function normalizedName(value)
    value = trim(value)
    if value == '' then
        return nil
    end
    return string.lower(value)
end

local function safeDisplayText(value, fallback)
    if type(value) ~= 'string' then
        return fallback
    end

    value = value:gsub('[%z\1-\31\127]', '')
    value = trim(value)
    if value == '' then
        return fallback
    end
    return value:sub(1, 80)
end

local function safeRequestId(value)
    if type(value) ~= 'string' and type(value) ~= 'number' then
        return nil
    end
    return tostring(value):sub(1, 128)
end

local function notify(playerSource, message, notificationType)
    TriggerClientEvent(EVENT_PREFIX .. ':client:notify', playerSource, {
        message = tostring(message or 'Unknown error'),
        type = notificationType or 'info',
    })
end

local function saveResult(playerSource, payload, ok, extra)
    extra = extra or {}
    local result = {
        requestId = safeRequestId(payload and payload.requestId),
        fieldId = type(payload and payload.fieldId) == 'string' and payload.fieldId or nil,
        ok = ok == true,
    }

    for key, value in pairs(extra) do
        result[key] = value
    end

    TriggerClientEvent(EVENT_PREFIX .. ':client:saveResult', playerSource, result)
end

local function restartResult(playerSource, payload, ok, extra)
    extra = extra or {}
    local result = {
        requestId = safeRequestId(payload and payload.requestId),
        ok = ok == true,
    }

    for key, value in pairs(extra) do
        result[key] = value
    end

    TriggerClientEvent(EVENT_PREFIX .. ':client:restartResult', playerSource, result)
end

local function xmlDecode(value)
    value = tostring(value or '')
    value = value:gsub('&#x([%da-fA-F]+);', function(hex)
        local codepoint = tonumber(hex, 16)
        if not codepoint or codepoint < 0 or codepoint > 0x10FFFF then
            return '&#x' .. hex .. ';'
        end
        local ok, decoded = pcall(utf8.char, codepoint)
        return ok and decoded or ('&#x' .. hex .. ';')
    end)
    value = value:gsub('&#(%d+);', function(decimal)
        local codepoint = tonumber(decimal, 10)
        if not codepoint or codepoint < 0 or codepoint > 0x10FFFF then
            return '&#' .. decimal .. ';'
        end
        local ok, decoded = pcall(utf8.char, codepoint)
        return ok and decoded or ('&#' .. decimal .. ';')
    end)
    value = value:gsub('&quot;', '"')
    value = value:gsub('&apos;', "'")
    value = value:gsub('&lt;', '<')
    value = value:gsub('&gt;', '>')
    value = value:gsub('&amp;', '&')
    return value
end

local function xmlEscapeText(value)
    value = tostring(value or '')
    value = value:gsub('&', '&amp;')
    value = value:gsub('<', '&lt;')
    value = value:gsub('>', '&gt;')
    return value
end

local function xmlEscapeAttribute(value, quote)
    value = xmlEscapeText(value)
    if quote == "'" then
        return value:gsub("'", '&apos;')
    end
    return value:gsub('"', '&quot;')
end

local function findTagEnd(xml, startAt)
    local quote = nil
    for position = startAt, #xml do
        local character = xml:sub(position, position)
        if quote then
            if character == quote then
                quote = nil
            end
        elseif character == '"' or character == "'" then
            quote = character
        elseif character == '>' then
            return position
        end
    end
    return nil
end

local function parseAttributes(inside, tagStart)
    local attributes = {}
    local byLowerName = {}
    local index = 1
    local _, tagEnd = inside:find('^%s*[%w_:%-%.]+')
    index = (tagEnd or 0) + 1

    while index <= #inside do
        while index <= #inside and inside:sub(index, index):match('%s') do
            index = index + 1
        end
        if inside:sub(index, index) == '/' then
            break
        end

        local nameStart, nameEnd = inside:find('[%w_:%-%.]+', index)
        if nameStart ~= index then
            index = index + 1
        else
            local name = inside:sub(nameStart, nameEnd)
            index = nameEnd + 1
            while index <= #inside and inside:sub(index, index):match('%s') do
                index = index + 1
            end

            if inside:sub(index, index) ~= '=' then
                attributes[#attributes + 1] = { name = name, value = '' }
                byLowerName[string.lower(name)] = attributes[#attributes]
            else
                index = index + 1
                while index <= #inside and inside:sub(index, index):match('%s') do
                    index = index + 1
                end

                local quote = inside:sub(index, index)
                if quote ~= '"' and quote ~= "'" then
                    local valueStart, valueEnd = inside:find('[^%s/>]+', index)
                    if valueStart == index then
                        local attribute = {
                            name = name,
                            value = xmlDecode(inside:sub(valueStart, valueEnd)),
                            raw = inside:sub(valueStart, valueEnd),
                            valueStart = tagStart + valueStart,
                            valueEnd = tagStart + valueEnd,
                            quote = '"',
                        }
                        attributes[#attributes + 1] = attribute
                        byLowerName[string.lower(name)] = attribute
                        index = valueEnd + 1
                    end
                else
                    local closingQuote = inside:find(quote, index + 1, true)
                    if not closingQuote then
                        break
                    end
                    local valueStart = index + 1
                    local valueEnd = closingQuote - 1
                    local raw = inside:sub(valueStart, valueEnd)
                    local attribute = {
                        name = name,
                        value = xmlDecode(raw),
                        raw = raw,
                        valueStart = tagStart + valueStart,
                        valueEnd = tagStart + valueEnd,
                        quote = quote,
                    }
                    attributes[#attributes + 1] = attribute
                    byLowerName[string.lower(name)] = attribute
                    index = closingQuote + 1
                end
            end
        end
    end

    return attributes, byLowerName
end

-- Lightweight XML structural parser. It does not normalize/re-serialize XML;
-- nodes retain byte offsets so saves can replace only the chosen value bytes.
local function parseXml(xml)
    if type(xml) ~= 'string' or #xml == 0 or #xml > MAX_XML_BYTES then
        return nil, 'The metadata file is empty or too large to edit safely.'
    end

    local roots = {}
    local stack = {}
    local position = 1

    while position <= #xml do
        local tagStart = xml:find('<', position, true)
        if not tagStart then
            break
        end

        if xml:sub(tagStart, tagStart + 3) == '<!--' then
            local commentEnd = xml:find('-->', tagStart + 4, true)
            if not commentEnd then
                return nil, 'Unterminated XML comment.'
            end
            position = commentEnd + 3
        elseif xml:sub(tagStart, tagStart + 8) == '<![CDATA[' then
            local cdataEnd = xml:find(']]>', tagStart + 9, true)
            if not cdataEnd then
                return nil, 'Unterminated XML CDATA section.'
            end
            position = cdataEnd + 3
        elseif xml:sub(tagStart, tagStart + 1) == '<?' then
            local instructionEnd = xml:find('?>', tagStart + 2, true)
            if not instructionEnd then
                return nil, 'Unterminated XML processing instruction.'
            end
            position = instructionEnd + 2
        elseif xml:sub(tagStart, tagStart + 1) == '<!' then
            local declarationEnd = findTagEnd(xml, tagStart + 2)
            if not declarationEnd then
                return nil, 'Unterminated XML declaration.'
            end
            position = declarationEnd + 1
        else
            local tagEnd = findTagEnd(xml, tagStart + 1)
            if not tagEnd then
                return nil, 'Unterminated XML tag.'
            end

            local inside = xml:sub(tagStart + 1, tagEnd - 1)
            local isClosing = inside:match('^%s*/') ~= nil

            if isClosing then
                local closingName = inside:match('^%s*/%s*([%w_:%-%.]+)')
                if not closingName or #stack == 0 then
                    return nil, 'Unexpected XML closing tag.'
                end

                local node = stack[#stack]
                if string.lower(node.name) ~= string.lower(closingName) then
                    return nil, ('Mismatched XML closing tag: expected </%s>, found </%s>.')
                        :format(node.name, closingName)
                end

                node.closeStart = tagStart
                node.finish = tagEnd
                stack[#stack] = nil
            else
                local name = inside:match('^%s*([%w_:%-%.]+)')
                if not name then
                    return nil, 'Invalid XML tag.'
                end

                local selfClosing = inside:match('/%s*$') ~= nil
                local attributes, attributesByName = parseAttributes(inside, tagStart)
                local parent = stack[#stack]
                local node = {
                    name = name,
                    start = tagStart,
                    openEnd = tagEnd,
                    closeStart = selfClosing and tagEnd or nil,
                    finish = selfClosing and tagEnd or nil,
                    selfClosing = selfClosing,
                    attributes = attributes,
                    attributesByName = attributesByName,
                    children = {},
                    parent = parent,
                }

                if parent then
                    parent.children[#parent.children + 1] = node
                else
                    roots[#roots + 1] = node
                end

                if not selfClosing then
                    stack[#stack + 1] = node
                end
            end

            position = tagEnd + 1
        end
    end

    if #stack > 0 then
        return nil, ('Unclosed XML tag <%s>.'):format(stack[#stack].name)
    end
    if #roots == 0 then
        return nil, 'No XML root element was found.'
    end
    return roots
end

local function walkNodes(nodes, callback)
    for _, node in ipairs(nodes) do
        callback(node)
        if #node.children > 0 then
            walkNodes(node.children, callback)
        end
    end
end

local function getNodeText(xml, node)
    if node.selfClosing or not node.closeStart then
        return ''
    end
    return trim(xmlDecode(xml:sub(node.openEnd + 1, node.closeStart - 1)))
end

local function directChild(node, wantedName)
    wantedName = string.lower(wantedName)
    for _, child in ipairs(node.children) do
        if string.lower(child.name) == wantedName then
            return child
        end
    end
    return nil
end

local function directChildText(xml, node, wantedName)
    local child = directChild(node, wantedName)
    return child and getNodeText(xml, child) or nil
end

local function getAttribute(node, attributeName)
    return node.attributesByName[string.lower(attributeName)]
end

local function findHandlingEntries(xml, roots)
    local entries = {}
    walkNodes(roots, function(node)
        if string.lower(node.name) ~= 'item' then
            return
        end

        local handlingName = directChildText(xml, node, 'handlingName')
        if handlingName and handlingName ~= '' then
            entries[#entries + 1] = {
                name = handlingName,
                normalizedName = normalizedName(handlingName),
                node = node,
            }
        end
    end)
    return entries
end

local function findVehicleEntries(xml, roots)
    local entries = {}
    walkNodes(roots, function(node)
        if string.lower(node.name) ~= 'item' then
            return
        end

        local modelName = directChildText(xml, node, 'modelName')
        local handlingId = directChildText(xml, node, 'handlingId')
        if modelName and modelName ~= '' and handlingId and handlingId ~= '' then
            entries[#entries + 1] = {
                modelName = modelName,
                handlingId = handlingId,
                gameName = directChildText(xml, node, 'gameName'),
            }
        end
    end)
    return entries
end

local function normalizeResourcePath(path, allowGlob)
    if type(path) ~= 'string' then
        return nil
    end

    path = trim(path):gsub('\\', '/')
    while path:sub(1, 2) == './' do
        path = path:sub(3)
    end
    path = path:gsub('/+', '/')

    if path == '' or path:sub(1, 1) == '/' or path:sub(1, 1) == '@' or path:find('%z') then
        return nil
    end
    if path:find('^%.%.$') or path:find('^%.%./') or path:find('/%.%./') or path:find('/%.%.$') then
        return nil
    end
    if not allowGlob and path:find('[%*%?]') then
        return nil
    end
    return path
end

local function collectStrings(value, output)
    if type(value) == 'string' then
        output[#output + 1] = value
    elseif type(value) == 'table' then
        for _, child in pairs(value) do
            collectStrings(child, output)
        end
    end
end

local function decodeMetadataExtra(raw)
    local strings = {}
    if type(raw) ~= 'string' or raw == '' then
        return strings
    end

    local ok, decoded = pcall(json.decode, raw)
    if ok then
        collectStrings(decoded, strings)
    else
        strings[1] = raw
    end
    return strings
end

local function quotedStringsNear(text, startAt, maximumLength)
    local values = {}
    local finishAt = math.min(#text, startAt + maximumLength)
    local position = startAt

    while position <= finishAt and #values < 2 do
        while position <= finishAt do
            local separator = text:sub(position, position)
            if separator:match('%s') or separator == '(' or separator == ')' or separator == ',' then
                position = position + 1
            else
                break
            end
        end

        local quote = text:sub(position, position)
        if quote ~= "'" and quote ~= '"' then
            break
        end

        local cursor = position + 1
        local value = {}
        while cursor <= finishAt do
            local character = text:sub(cursor, cursor)
            if character == '\\' and cursor < finishAt then
                value[#value + 1] = text:sub(cursor + 1, cursor + 1)
                cursor = cursor + 2
            elseif character == quote then
                values[#values + 1] = table.concat(value)
                position = cursor + 1
                break
            else
                value[#value + 1] = character
                cursor = cursor + 1
            end
        end
        if cursor > finishAt then
            break
        end
    end
    return values
end

local function skipLuaQuotedString(text, startAt)
    local quote = text:sub(startAt, startAt)
    local position = startAt + 1
    while position <= #text do
        local character = text:sub(position, position)
        if character == '\\' then
            position = position + 2
        elseif character == quote then
            return position + 1
        else
            position = position + 1
        end
    end
    return #text + 1
end

local function skipLuaLongBracket(text, startAt)
    local openStart, openEnd, equals = text:find('%[(=*)%[', startAt)
    if openStart ~= startAt then
        return nil
    end

    local closeMarker = ']' .. equals .. ']'
    local _, closeEnd = text:find(closeMarker, openEnd + 1, true)
    return closeEnd and (closeEnd + 1) or (#text + 1)
end

local function manifestFallbackPatterns(resourceName, wantedType)
    local manifest = LoadResourceFile(resourceName, 'fxmanifest.lua')
        or LoadResourceFile(resourceName, '__resource.lua')
    local patterns = {}
    if not manifest then
        return patterns
    end

    -- Scan only executable Lua text. A plain string search can resurrect a
    -- data_file declaration that an operator deliberately commented out.
    local position = 1
    while position <= #manifest do
        local character = manifest:sub(position, position)
        if character == "'" or character == '"' then
            position = skipLuaQuotedString(manifest, position)
        elseif character == '-' and manifest:sub(position + 1, position + 1) == '-' then
            local afterComment = skipLuaLongBracket(manifest, position + 2)
            if afterComment then
                position = afterComment
            else
                position = manifest:find('[\r\n]', position + 2) or (#manifest + 1)
            end
        elseif character == '[' then
            position = skipLuaLongBracket(manifest, position) or (position + 1)
        elseif manifest:sub(position, position + 8) == 'data_file' then
            local before = position > 1 and manifest:sub(position - 1, position - 1) or ''
            local after = manifest:sub(position + 9, position + 9)
            if not before:match('[%w_]') and not after:match('[%w_]') then
                local values = quotedStringsNear(manifest, position + 9, 768)
                if values[1] and string.upper(values[1]) == wantedType and values[2] then
                    patterns[#patterns + 1] = values[2]
                end
            end
            position = position + 9
        else
            position = position + 1
        end
    end
    return patterns
end

local function manifestDataFilePatterns(resourceName, wantedType)
    local patterns = {}
    local seen = {}
    local metadataCount = GetNumResourceMetadata(resourceName, 'data_file') or 0

    for index = 0, metadataCount - 1 do
        local primary = GetResourceMetadata(resourceName, 'data_file', index)
        local extra = GetResourceMetadata(resourceName, 'data_file_extra', index)
        local candidates = decodeMetadataExtra(extra)

        if type(primary) == 'string' and string.upper(primary) == wantedType then
            for _, candidate in ipairs(candidates) do
                local normalized = normalizeResourcePath(candidate, true)
                if normalized and not seen[normalized] then
                    seen[normalized] = true
                    patterns[#patterns + 1] = normalized
                end
            end
        else
            -- Tolerate alternate metadata layouts where the path is primary and
            -- the data-file type is encoded in the generated extra metadata.
            local extraContainsType = false
            for _, candidate in ipairs(candidates) do
                if string.upper(candidate) == wantedType then
                    extraContainsType = true
                    break
                end
            end
            if extraContainsType then
                local normalized = normalizeResourcePath(primary, true)
                if normalized and not seen[normalized] then
                    seen[normalized] = true
                    patterns[#patterns + 1] = normalized
                end
            end
        end
    end

    -- Some runtimes expose only part of a large manifest's data_file metadata.
    -- Merge active source declarations so late wildcard entries are not lost.
    -- manifestFallbackPatterns skips Lua strings and comments, so inactive
    -- declarations are not accidentally made writable.
    for _, candidate in ipairs(manifestFallbackPatterns(resourceName, wantedType)) do
        local normalized = normalizeResourcePath(candidate, true)
        if normalized and not seen[normalized] then
            seen[normalized] = true
            patterns[#patterns + 1] = normalized
        end
    end

    table.sort(patterns)
    return patterns
end

local function manifestCustomPatterns(resourceName, metadataKey)
    local patterns = {}
    local seen = {}
    local count = GetNumResourceMetadata(resourceName, metadataKey) or 0
    for index = 0, count - 1 do
        local normalized = normalizeResourcePath(
            GetResourceMetadata(resourceName, metadataKey, index), true)
        if normalized and not seen[normalized] then
            seen[normalized] = true
            patterns[#patterns + 1] = normalized
        end
    end
    table.sort(patterns)
    return patterns
end

local function manifestFileCandidates(resourceName)
    local candidates = {}
    local count = GetNumResourceMetadata(resourceName, 'file') or 0
    for index = 0, count - 1 do
        local value = normalizeResourcePath(GetResourceMetadata(resourceName, 'file', index), false)
        if value then
            candidates[value] = true
        end
    end
    return candidates
end

local function readDirectory(resourceName, relativePath)
    if type(io.readdir) ~= 'function' then
        return nil
    end

    local mountPath = '@' .. resourceName .. '/'
    if relativePath ~= '' then
        mountPath = mountPath .. relativePath
    end

    local candidatePaths = { mountPath }
    if type(GetResourcePath) == 'function' then
        local pathOk, resourcePath = pcall(GetResourcePath, resourceName)
        if pathOk and type(resourcePath) == 'string' and resourcePath ~= '' then
            resourcePath = resourcePath:gsub('[\\/]+$', '')
            candidatePaths[#candidatePaths + 1] = relativePath == ''
                and resourcePath
                or (resourcePath .. '/' .. relativePath)
        end
    end

    for _, candidatePath in ipairs(candidatePaths) do
        local ok, handle = pcall(io.readdir, candidatePath)
        if ok and handle then
            local names = {}
            local readOk = pcall(function()
                for name in handle:lines() do
                    if name ~= '.' and name ~= '..'
                        and not name:find('[\\/%z]')
                    then
                        names[#names + 1] = name
                    end
                end
            end)
            pcall(function()
                handle:close()
            end)

            if readOk then
                table.sort(names)
                return names
            end
        end
    end
    return nil
end

local function listResourceFiles(resourceName, basePath)
    local files = {}
    local stopped = false

    local function visit(relativePath, depth)
        if stopped or depth > MAX_DIRECTORY_DEPTH then
            return
        end

        local names = readDirectory(resourceName, relativePath)
        if not names then
            return
        end

        for _, name in ipairs(names) do
            local child = relativePath == '' and name or (relativePath .. '/' .. name)
            local childDirectory = readDirectory(resourceName, child)
            if childDirectory then
                visit(child, depth + 1)
            else
                files[#files + 1] = child
                if #files >= MAX_RESOURCE_FILES then
                    stopped = true
                    break
                end
            end
        end
    end

    visit(basePath or '', 0)
    return files, stopped
end

local LUA_PATTERN_MAGIC = {
    ['^'] = true, ['$'] = true, ['('] = true, [')'] = true,
    ['%'] = true, ['.'] = true, ['['] = true, [']'] = true,
    ['+'] = true, ['-'] = true,
}

local function globPattern(glob)
    local output = { '^' }
    local index = 1

    while index <= #glob do
        local character = glob:sub(index, index)
        if character == '*' then
            if glob:sub(index + 1, index + 2) == '*/' then
                -- `**/` also matches zero directory levels.
                output[#output + 1] = '.-'
                index = index + 3
            elseif glob:sub(index + 1, index + 1) == '*' then
                output[#output + 1] = '.*'
                index = index + 2
            else
                output[#output + 1] = '[^/]*'
                index = index + 1
            end
        elseif character == '?' then
            output[#output + 1] = '[^/]'
            index = index + 1
        else
            output[#output + 1] = LUA_PATTERN_MAGIC[character] and ('%' .. character) or character
            index = index + 1
        end
    end

    output[#output + 1] = '$'
    return table.concat(output)
end

local function staticGlobBase(pattern)
    local wildcardAt = pattern:find('[%*%?]')
    if not wildcardAt then
        return ''
    end
    local prefix = pattern:sub(1, wildcardAt - 1)
    local slashAt = prefix:match('^.*()/')
    if not slashAt then
        return ''
    end
    return prefix:sub(1, slashAt - 1)
end

local function expandPatterns(resourceName, patterns)
    local paths = {}
    local seen = {}
    local listingCache = {}
    local metadataFiles = manifestFileCandidates(resourceName)

    local function add(path)
        path = normalizeResourcePath(path, false)
        -- Backups deliberately live beside handling files and can therefore
        -- match broad declarations such as `**/*.meta*`. They must never become
        -- metadata sources or writable session targets.
        local isEditorBackup = path
            and string.lower(path):sub(-#'.chandlingeditor.bak') == '.chandlingeditor.bak'
        if path and not isEditorBackup and not seen[path] then
            seen[path] = true
            paths[#paths + 1] = path
        end
    end

    for _, pattern in ipairs(patterns) do
        if not pattern:find('[%*%?]') then
            add(pattern)
        else
            local matcher = globPattern(pattern)
            for candidate in pairs(metadataFiles) do
                if candidate:match(matcher) then
                    add(candidate)
                end
            end

            local basePath = staticGlobBase(pattern)
            local cacheKey = basePath
            if not listingCache[cacheKey] then
                local listed, truncated = listResourceFiles(resourceName, basePath)
                listingCache[cacheKey] = listed
                if truncated then
                    log(('Stopped recursive discovery in @%s/%s after %d files.')
                        :format(resourceName, basePath, MAX_RESOURCE_FILES))
                end
            end
            for _, candidate in ipairs(listingCache[cacheKey]) do
                if candidate:match(matcher) then
                    add(candidate)
                end
            end
        end
    end

    table.sort(paths)
    return paths
end

local function loadXml(resourceName, path)
    local content = LoadResourceFile(resourceName, path)
    if type(content) ~= 'string' then
        return nil, ('Could not read @%s/%s (missing, escrowed, or inaccessible).')
            :format(resourceName, path)
    end
    if #content > MAX_XML_BYTES then
        return nil, ('@%s/%s is larger than the %d MiB safety limit.')
            :format(resourceName, path, MAX_XML_BYTES // (1024 * 1024))
    end
    return content
end

local function buildIndex()
    local newIndex = {
        ready = true,
        generation = activeIndex.generation + 1,
        models = {},
        unresolvedModels = {},
        resources = {},
        modelCount = 0,
        handlingCount = 0,
    }

    local resourceCount = GetNumResources()
    for resourceIndex = 0, resourceCount - 1 do
        local resourceName = GetResourceByFindIndex(resourceIndex)
        local state = resourceName and GetResourceState(resourceName) or 'missing'

        if resourceName and resourceName ~= RESOURCE_NAME and state == 'started' then
            local handlingPatterns = manifestDataFilePatterns(resourceName, 'HANDLING_FILE')
            local vehiclePatterns = manifestDataFilePatterns(resourceName, 'VEHICLE_METADATA_FILE')
            local editorVehiclePatterns = manifestCustomPatterns(
                resourceName, 'chandling_vehicle_metadata')
            if #editorVehiclePatterns > 0 then
                -- A lightweight handling-only resource can carry non-mounted
                -- vehicles.meta copies solely for model -> handling indexing.
                -- This lets the editor restart handling data without hot-
                -- remounting the parent resource's streamed vehicle assets.
                vehiclePatterns = editorVehiclePatterns
            end

            if #vehiclePatterns > 0 then
                newIndex.resources[resourceName] = true
                local handlingByName = {}
                local handlingPaths = expandPatterns(resourceName, handlingPatterns)
                for _, handlingPath in ipairs(handlingPaths) do
                    local xml = loadXml(resourceName, handlingPath)
                    if xml then
                        local roots, parseError = parseXml(xml)
                        if roots then
                            for _, entry in ipairs(findHandlingEntries(xml, roots)) do
                                local entries = handlingByName[entry.normalizedName]
                                if not entries then
                                    entries = {}
                                    handlingByName[entry.normalizedName] = entries
                                end
                                entries[#entries + 1] = {
                                    name = entry.name,
                                    path = handlingPath,
                                }
                                newIndex.handlingCount = newIndex.handlingCount + 1
                            end
                        else
                            log(('Skipping invalid @%s/%s: %s'):format(resourceName, handlingPath, parseError))
                        end
                    end
                end

                local vehiclePaths = expandPatterns(resourceName, vehiclePatterns)
                for _, vehiclePath in ipairs(vehiclePaths) do
                    local xml = loadXml(resourceName, vehiclePath)
                    if xml then
                        local roots, parseError = parseXml(xml)
                        if roots then
                            for _, vehicle in ipairs(findVehicleEntries(xml, roots)) do
                                local hash = joaat(vehicle.modelName)
                                local hashKey = tostring(hash)
                                local handlers = handlingByName[normalizedName(vehicle.handlingId)] or {}

                                if #handlers == 1 then
                                    local handler = handlers[1]
                                    local candidates = newIndex.models[hashKey]
                                    if not candidates then
                                        candidates = {}
                                        newIndex.models[hashKey] = candidates
                                    end
                                    candidates[#candidates + 1] = {
                                        modelHash = hash,
                                        modelName = vehicle.modelName,
                                        displayName = vehicle.gameName ~= '' and vehicle.gameName or vehicle.modelName,
                                        vehiclePath = vehiclePath,
                                        resource = resourceName,
                                        handlingName = handler.name,
                                        handlingPath = handler.path,
                                    }
                                    newIndex.modelCount = newIndex.modelCount + 1
                                else
                                    local unresolved = newIndex.unresolvedModels[hashKey]
                                    if not unresolved then
                                        unresolved = {}
                                        newIndex.unresolvedModels[hashKey] = unresolved
                                    end
                                    unresolved[#unresolved + 1] = {
                                        modelName = vehicle.modelName,
                                        resource = resourceName,
                                        reason = #handlers == 0
                                            and ('No readable handling entry named %s was found in this resource.')
                                            or ('More than one handling entry named %s exists in this resource.'),
                                        handlingId = vehicle.handlingId,
                                    }
                                end
                            end
                        else
                            log(('Skipping invalid @%s/%s: %s'):format(resourceName, vehiclePath, parseError))
                        end
                    end
                end
            end
        end

        if resourceIndex % 25 == 0 then
            Wait(0)
        end
    end

    return newIndex
end

local function invalidateSessionsForResource(resourceName, reason)
    for playerSource, session in pairs(sessions) do
        if session.resource == resourceName then
            sessions[playerSource] = nil
            TriggerClientEvent(EVENT_PREFIX .. ':client:close', playerSource, {
                reason = reason or 'resource_changed',
            })
            notify(playerSource, 'The edited vehicle resource changed. Reopen the editor to refresh its fields.', 'warning')
        end
    end
end

local function runIndexScan()
    if scanRunning then
        scanAgain = true
        return
    end

    scanRunning = true
    local ok, result = xpcall(buildIndex, debug.traceback)
    if ok then
        activeIndex = result
        log(('Indexed %d vehicle mapping(s) and %d handling entry/entries (generation %d).')
            :format(result.modelCount, result.handlingCount, result.generation))
    else
        log('Handling metadata scan failed: ' .. tostring(result))
        activeIndex.ready = activeIndex.ready == true
    end
    scanRunning = false

    if scanAgain then
        scanAgain = false
        SetTimeout(250, runIndexScan)
    end
end

local function scheduleIndexScan(delay)
    if scanTimerPending then
        return
    end
    scanTimerPending = true
    SetTimeout(delay or 250, function()
        scanTimerPending = false
        runIndexScan()
    end)
end

local function resourceHasVehicleMetadata(resourceName)
    if not resourceName or resourceName == RESOURCE_NAME then return false end
    if activeIndex.resources[resourceName] then return true end

    return #manifestDataFilePatterns(resourceName, 'VEHICLE_METADATA_FILE') > 0
        or #manifestDataFilePatterns(resourceName, 'HANDLING_FILE') > 0
        or #manifestCustomPatterns(resourceName, 'chandling_vehicle_metadata') > 0
end

local function prettyLabel(name)
    local label = tostring(name or 'Field')
    if label:match('^vec%u') then
        label = label:sub(4)
    elseif label:match('^str%u') then
        label = label:sub(4)
    end
    if label:match('^[fnb]%u') then
        label = label:sub(2)
    end
    label = label:gsub('(%l)(%u)', '%1 %2')
    label = label:gsub('(%u)(%u%l)', '%1 %2')
    label = trim(label)
    return label ~= '' and label or tostring(name)
end

local function prettyClassName(className)
    local label = tostring(className or 'CHandlingData')
    label = label:gsub('^C', '')
    label = label:gsub('(%l)(%u)', '%1 %2')
    return trim(label)
end

local function rawTextSpan(xml, node)
    if node.selfClosing or not node.closeStart or #node.children > 0 then
        return nil
    end

    local raw = xml:sub(node.openEnd + 1, node.closeStart - 1)
    if raw:find('<', 1, true) then
        return nil
    end
    local leading = raw:match('^%s*') or ''
    local trailing = raw:match('%s*$') or ''
    local valueStart = node.openEnd + 1 + #leading
    local valueEnd = node.closeStart - 1 - #trailing
    if valueEnd < valueStart then
        return nil
    end
    return {
        raw = xml:sub(valueStart, valueEnd),
        valueStart = valueStart,
        valueEnd = valueEnd,
        quote = nil,
    }
end

local function numericType(fieldName, raw, value)
    -- GTA convention is semantically stronger than lexical formatting: float
    -- fields are often shipped as `value="1000"`, while still accepting decimal
    -- edits and requiring SetVehicleHandlingFloat for live preview.
    if tostring(fieldName):match('^f%u') then
        return 'number'
    end
    if tostring(fieldName):match('^n%u') or string.lower(tostring(fieldName)) == 'mode' then
        return 'integer'
    end
    if raw:match('^[+-]?%d+$') and value % 1 == 0 then
        return 'integer'
    end
    return 'number'
end

local function describeLeaf(xml, node, className)
    if #node.children > 0 or string.lower(node.name) == 'handlingname' then
        return nil
    end

    -- The documented SetVehicleHandling* natives guarantee CHandlingData.
    -- Nested sub-handling classes remain editable on disk but are intentionally
    -- file-only to avoid unsafe live-native calls on unsupported game builds.
    local supportsLiveNative = string.lower(className or '') == 'chandlingdata'
    local x = getAttribute(node, 'x')
    local y = getAttribute(node, 'y')
    local z = getAttribute(node, 'z')
    if x and y and z then
        local xValue, yValue, zValue = tonumber(x.value), tonumber(y.value), tonumber(z.value)
        if finiteNumber(xValue) and finiteNumber(yValue) and finiteNumber(zValue) then
            return {
                name = node.name,
                class = className,
                type = 'vector',
                value = { x = xValue, y = yValue, z = zValue },
                live = supportsLiveNative,
                spans = {
                    x = x,
                    y = y,
                    z = z,
                },
                representation = 'vector_attributes',
            }
        end
    end

    local valueAttribute = getAttribute(node, 'value')
    if valueAttribute then
        local numberValue = tonumber(valueAttribute.value)
        if finiteNumber(numberValue) then
            local valueType = numericType(node.name, trim(valueAttribute.value), numberValue)
            return {
                name = node.name,
                class = className,
                type = valueType,
                value = numberValue,
                live = supportsLiveNative,
                spans = { value = valueAttribute },
                representation = 'value_attribute',
            }
        end

        return {
            name = node.name,
            class = className,
            type = 'text',
            value = valueAttribute.value,
            live = false,
            spans = { value = valueAttribute },
            representation = 'value_attribute',
        }
    end

    local textSpan = rawTextSpan(xml, node)
    if textSpan then
        return {
            name = node.name,
            class = className,
            type = 'text',
            value = xmlDecode(textSpan.raw),
            live = false,
            spans = { value = textSpan },
            representation = 'text',
        }
    end
    return nil
end

local function buildFields(xml, entryNode)
    local groups = {}
    local groupByClass = {}
    local fieldsById = {}
    local fieldCount = 0
    local rootType = getAttribute(entryNode, 'type')
    local rootClass = rootType and rootType.value or 'CHandlingData'

    local function addField(descriptor, locator)
        if fieldCount >= MAX_FIELDS then
            return
        end
        fieldCount = fieldCount + 1

        local className = descriptor.class or 'CHandlingData'
        local group = groupByClass[className]
        if not group then
            group = {
                name = className,
                label = prettyClassName(className),
                fields = {},
            }
            groupByClass[className] = group
            groups[#groups + 1] = group
        end

        local fieldId = newToken('field')
        local publicField = {
            id = fieldId,
            name = descriptor.name,
            label = prettyLabel(descriptor.name),
            class = className,
            type = descriptor.type,
            value = copyValue(descriptor.value),
            originalValue = copyValue(descriptor.value),
            live = descriptor.live == true,
            restartRequired = descriptor.live ~= true,
        }
        group.fields[#group.fields + 1] = publicField

        fieldsById[fieldId] = {
            id = fieldId,
            name = descriptor.name,
            class = className,
            type = descriptor.type,
            locator = locator,
            currentValue = copyValue(descriptor.value),
            live = descriptor.live == true,
        }
    end

    local function walk(parent, className, locator)
        for childIndex, child in ipairs(parent.children) do
            local childLocator = copyValue(locator)
            childLocator[#childLocator + 1] = childIndex
            local childClass = className
            local childName = string.lower(child.name)

            if childName == 'item' then
                local typeAttribute = getAttribute(child, 'type')
                if typeAttribute and string.upper(typeAttribute.value) == 'NULL' then
                    goto continue
                end
                if typeAttribute and trim(typeAttribute.value) ~= '' then
                    childClass = typeAttribute.value
                end
            end

            if #child.children == 0 then
                local descriptor = describeLeaf(xml, child, childClass)
                if descriptor then
                    addField(descriptor, childLocator)
                end
            else
                walk(child, childClass, childLocator)
            end

            ::continue::
        end
    end

    walk(entryNode, rootClass, {})
    return groups, fieldsById, fieldCount
end

local function findUniqueHandlingEntry(xml, wantedName)
    local roots, parseError = parseXml(xml)
    if not roots then
        return nil, parseError
    end

    local wanted = normalizedName(wantedName)
    local found = {}
    for _, entry in ipairs(findHandlingEntries(xml, roots)) do
        if entry.normalizedName == wanted then
            found[#found + 1] = entry.node
        end
    end

    if #found == 0 then
        return nil, ('The handling entry %s no longer exists.'):format(wantedName)
    elseif #found > 1 then
        return nil, ('The handling entry %s is ambiguous in its file.'):format(wantedName)
    end
    return found[1]
end

local function resolveLocator(entryNode, locator)
    local node = entryNode
    for _, childIndex in ipairs(locator) do
        if type(childIndex) ~= 'number' or not node.children[childIndex] then
            return nil
        end
        node = node.children[childIndex]
    end
    return node
end

local function valueEquals(left, right, valueType)
    if valueType == 'vector' then
        return type(left) == 'table'
            and type(right) == 'table'
            and tonumber(left.x) == tonumber(right.x)
            and tonumber(left.y) == tonumber(right.y)
            and tonumber(left.z) == tonumber(right.z)
    elseif valueType == 'number' or valueType == 'integer' then
        return tonumber(left) == tonumber(right)
    end
    return tostring(left or '') == tostring(right or '')
end

local function validateNumber(value, integer)
    if type(value) == 'string' then
        value = tonumber(trim(value))
    end
    if not finiteNumber(value) or math.abs(value) > 1e12 then
        return nil, 'Enter a finite number between -1e12 and 1e12.'
    end
    if integer and value % 1 ~= 0 then
        return nil, 'Enter a whole number.'
    end
    return value
end

local function validateFieldValue(field, value)
    if field.type == 'number' then
        return validateNumber(value, false)
    elseif field.type == 'integer' then
        return validateNumber(value, true)
    elseif field.type == 'vector' then
        if type(value) ~= 'table' then
            return nil, 'Enter all three vector components.'
        end
        local x, xError = validateNumber(value.x, false)
        local y, yError = validateNumber(value.y, false)
        local z, zError = validateNumber(value.z, false)
        if not x or not y or not z then
            return nil, xError or yError or zError
        end
        return { x = x, y = y, z = z }
    end

    if type(value) ~= 'string' then
        return nil, 'Enter a text value.'
    end
    value = value:gsub('[%z\1-\8\11\12\14-\31]', '')
    if #value > 512 then
        return nil, 'Text values are limited to 512 characters.'
    end
    return value
end

local function formatNumber(value, oldRaw, integer)
    if integer then
        return ('%.0f'):format(value)
    end

    oldRaw = trim(oldRaw)
    if oldRaw:find('[eE]') then
        return ('%.12g'):format(value)
    end

    local decimals = oldRaw:match('%.(%d+)')
    local precision = math.max(decimals and #decimals or 0, 6)
    precision = math.min(precision, 12)
    return (('%.' .. precision .. 'f'):format(value))
end

local function replacementsForValue(descriptor, newValue)
    local replacements = {}

    if descriptor.type == 'vector' then
        for _, axis in ipairs({ 'x', 'y', 'z' }) do
            local span = descriptor.spans[axis]
            replacements[#replacements + 1] = {
                start = span.valueStart,
                finish = span.valueEnd,
                oldRaw = span.raw,
                replacement = formatNumber(newValue[axis], span.raw, false),
            }
        end
    else
        local span = descriptor.spans.value
        local replacement
        if descriptor.type == 'number' then
            replacement = formatNumber(newValue, span.raw, false)
        elseif descriptor.type == 'integer' then
            replacement = formatNumber(newValue, span.raw, true)
        elseif descriptor.representation == 'value_attribute' then
            replacement = xmlEscapeAttribute(newValue, span.quote)
        else
            replacement = xmlEscapeText(newValue)
        end

        replacements[1] = {
            start = span.valueStart,
            finish = span.valueEnd,
            oldRaw = span.raw,
            replacement = replacement,
        }
    end
    return replacements
end

local function applyReplacements(content, replacements)
    table.sort(replacements, function(left, right)
        return left.start > right.start
    end)

    local lastStart = #content + 1
    for _, replacement in ipairs(replacements) do
        if replacement.start < 1 or replacement.finish >= lastStart then
            return nil, 'The metadata value offsets overlap or are invalid.'
        end
        if content:sub(replacement.start, replacement.finish) ~= replacement.oldRaw then
            return nil, 'The metadata value changed while the save was being prepared.'
        end
        content = content:sub(1, replacement.start - 1)
            .. replacement.replacement
            .. content:sub(replacement.finish + 1)
        lastStart = replacement.start
    end
    return content
end

local function permissionSuggestion(resourceName)
    return ('add_filesystem_permission %s write %s'):format(RESOURCE_NAME, resourceName)
end

local function saveResourceContent(resourceName, path, content)
    local ok, result = pcall(SaveResourceFile, resourceName, path, content, #content)
    if not ok or result == false then
        return false
    end

    local confirmed = LoadResourceFile(resourceName, path)
    return confirmed == content
end

local function saveWithBackup(resourceName, path, oldContent, newContent)
    local backupPath = path .. '.cHandlingEditor.bak'
    local existingBackup = LoadResourceFile(resourceName, backupPath)

    if existingBackup == nil and not saveResourceContent(resourceName, backupPath, oldContent) then
        return nil, ('Could not create @%s/%s. This may be a filesystem-permission or other I/O failure. '
            .. 'If cross-resource write permission is missing, add this line to server.cfg and restart FXServer: %s')
            :format(resourceName, backupPath, permissionSuggestion(resourceName))
    end

    if not saveResourceContent(resourceName, path, newContent) then
        return nil, ('Could not write @%s/%s. This may be a filesystem-permission or other I/O failure. '
            .. 'If cross-resource write permission is missing, add this line to server.cfg and restart FXServer: %s')
            :format(resourceName, path, permissionSuggestion(resourceName))
    end
    return true
end

local function enqueueFileTask(resourceName, path, task, onUnexpectedError)
    local key = resourceName .. '\0' .. path
    local queue = fileQueues[key]
    if not queue then
        queue = {}
        fileQueues[key] = queue
    end
    queue[#queue + 1] = {
        run = task,
        onUnexpectedError = onUnexpectedError,
    }

    if #queue > 1 then
        return
    end

    CreateThread(function()
        while queue[1] do
            local queuedTask = queue[1]
            local ok, taskError = xpcall(queuedTask.run, debug.traceback)
            if not ok then
                log(('Queued write for @%s/%s failed: %s'):format(resourceName, path, taskError))
                if queuedTask.onUnexpectedError then
                    local callbackOk, callbackError = pcall(queuedTask.onUnexpectedError)
                    if not callbackOk then
                        log(('Could not report queued write failure for @%s/%s: %s')
                            :format(resourceName, path, callbackError))
                    end
                end
            end
            table.remove(queue, 1)
            Wait(0)
        end
        fileQueues[key] = nil
    end)
end

local function actualDrivenVehicleModel(playerSource)
    if type(GetPlayerPed) ~= 'function'
        or type(GetVehiclePedIsIn) ~= 'function'
        or type(GetPedInVehicleSeat) ~= 'function'
        or type(GetEntityModel) ~= 'function'
    then
        return nil, 'Server-side entity validation is unavailable. Enable OneSync and retry.'
    end

    local ok, result, errorMessage = pcall(function()
        local ped = GetPlayerPed(playerSource)
        if not ped or ped == 0 then
            return nil, 'Your player entity is not available yet.'
        end

        local vehicle = GetVehiclePedIsIn(ped, false)
        if not vehicle or vehicle == 0 then
            return nil, 'You must be driving an add-on vehicle to use the handling editor.'
        end
        if GetPedInVehicleSeat(vehicle, -1) ~= ped then
            return nil, 'Only the driver can open the handling editor.'
        end

        local modelHash = normalizeHash(GetEntityModel(vehicle))
        if not modelHash then
            return nil, 'The server could not identify the current vehicle model.'
        end
        return modelHash
    end)

    if not ok then
        return nil, 'The server could not validate your current vehicle. Make sure OneSync is enabled.'
    end
    return result, errorMessage
end

local function selectModelRecord(modelHash)
    local hashKey = tostring(modelHash)
    local candidates = activeIndex.models[hashKey] or {}
    if #candidates == 1 then
        return candidates[1]
    elseif #candidates > 1 then
        local resources = {}
        for _, candidate in ipairs(candidates) do
            resources[candidate.resource] = true
        end
        local names = {}
        for resourceName in pairs(resources) do
            names[#names + 1] = resourceName
        end
        table.sort(names)
        return nil, ('This model is declared by multiple active resources (%s), so it cannot be edited safely.')
            :format(table.concat(names, ', '))
    end

    local unresolved = activeIndex.unresolvedModels[hashKey] or {}
    if #unresolved > 0 then
        local item = unresolved[1]
        return nil, ('Found %s in resource %s, but %s')
            :format(item.modelName, item.resource, item.reason:format(item.handlingId))
    end
    return nil, 'No writable add-on handling metadata was found for this vehicle. Stock GTA vehicles are not supported.'
end

local function modelRecordStillMapped(session)
    local candidates = activeIndex.models[tostring(session.modelHash)] or {}
    if #candidates ~= 1 then
        return false
    end
    local record = candidates[1]
    return record.resource == session.resource
        and record.handlingPath == session.handlingPath
        and normalizedName(record.handlingName) == normalizedName(session.handlingName)
end

local function broadcastRestartOverlay(attempt, visible, stage, detail)
    TriggerClientEvent(EVENT_PREFIX .. ':client:restartOverlay', -1, {
        transactionId = attempt.id,
        visible = visible == true,
        resource = attempt.resourceName,
        stage = stage,
        detail = detail,
    })
end

local function resourceModelHashes(resourceName)
    local hashes = {}
    local function collect(recordsByHash)
        for hashKey, records in pairs(recordsByHash) do
            for _, record in ipairs(records) do
                if record.resource == resourceName then
                    hashes[hashKey] = true
                    break
                end
            end
        end
    end
    collect(activeIndex.models)
    collect(activeIndex.unresolvedModels)
    return hashes
end

local function matchingResourceVehicles(resourceName, modelHashes)
    if type(GetAllVehicles) ~= 'function'
        or type(GetEntityModel) ~= 'function'
        or type(DoesEntityExist) ~= 'function'
    then
        return nil, 'Server-side vehicle enumeration is unavailable; the restart was cancelled.'
    end

    modelHashes = modelHashes or resourceModelHashes(resourceName)
    if next(modelHashes) == nil then
        return nil, ('No indexed vehicle models were found for %s; the restart was cancelled.'):format(resourceName)
    end

    local listed, vehicles = pcall(GetAllVehicles)
    if not listed or type(vehicles) ~= 'table' then
        return nil, 'The server could not enumerate live vehicles; the restart was cancelled.'
    end

    local matches = {}
    for _, vehicle in pairs(vehicles) do
        local existsOk, exists = pcall(DoesEntityExist, vehicle)
        local modelOk, rawModel = false, nil
        if existsOk and exists then
            modelOk, rawModel = pcall(GetEntityModel, vehicle)
        end
        local modelHash = modelOk and normalizeHash(rawModel) or nil
        if modelHash and modelHashes[tostring(modelHash)] then
            matches[#matches + 1] = vehicle
        end
    end
    return matches
end

local function nativeValue(native, fallback, ...)
    if type(native) ~= 'function' then return fallback end
    local ok, value = pcall(native, ...)
    if not ok or value == nil then return fallback end
    return value
end

local function snapshotVehicle(vehicle)
    local model = normalizeHash(nativeValue(GetEntityModel, nil, vehicle))
    local coords = nativeValue(GetEntityCoords, nil, vehicle)
    if not model or not coords then return nil end

    local stateValues = {}
    pcall(function()
        local state = Entity(vehicle).state
        stateValues.persisted = state.persisted == true
        stateValues.vehicleid = state.vehicleid
        stateValues.sessionId = state.sessionId
        stateValues.oxProperties = state['ox_lib:setVehicleProperties']
    end)

    local liveBasics = {
        model = model,
        plate = nativeValue(GetVehicleNumberPlateText, nil, vehicle),
        lockState = nativeValue(GetVehicleDoorLockStatus, nil, vehicle),
        bodyHealth = nativeValue(GetVehicleBodyHealth, nil, vehicle),
        engineHealth = nativeValue(GetVehicleEngineHealth, nil, vehicle),
        tankHealth = nativeValue(GetVehiclePetrolTankHealth, nil, vehicle),
        fuelLevel = nativeValue(GetVehicleFuelLevel, nil, vehicle),
        dirtLevel = nativeValue(GetVehicleDirtLevel, nil, vehicle),
    }
    local properties = copyValue(liveBasics)
    local exactProperties = false

    if type(stateValues.oxProperties) == 'table' then
        properties = copyValue(stateValues.oxProperties)
        exactProperties = true
    end

    -- A garage-owned vehicle has a durable properties record. Use it as the
    -- fallback, then replace it with the live owner's ox_lib snapshot below.
    if stateValues.vehicleid and GetResourceState('qbx_vehicles') == 'started' then
        local ok, storedVehicle = pcall(function()
            return exports.qbx_vehicles:GetPlayerVehicle(stateValues.vehicleid)
        end)
        if ok and type(storedVehicle) == 'table' and type(storedVehicle.props) == 'table' then
            properties = copyValue(storedVehicle.props)
            exactProperties = true
        end
    end
    -- Database/statebag props supply cosmetics and tuning; live server getters
    -- keep damage, fuel, lock state and plate current while the client owner is
    -- asked for a completely authoritative ox_lib snapshot.
    for key, value in pairs(liveBasics) do
        if value ~= nil then properties[key] = value end
    end
    properties.model = model

    local occupants = {}
    if type(GetPedInVehicleSeat) == 'function' then
        for seat = -1, 31 do
            local ped = nativeValue(GetPedInVehicleSeat, 0, vehicle, seat)
            if ped and ped ~= 0 then
                occupants[#occupants + 1] = { ped = ped, seat = seat }
            end
        end
    end

    return {
        originalEntity = vehicle,
        model = model,
        vehicleType = nativeValue(GetVehicleType, nil, vehicle),
        coords = { x = coords.x + 0.0, y = coords.y + 0.0, z = coords.z + 0.0 },
        heading = nativeValue(GetEntityHeading, 0.0, vehicle) + 0.0,
        rotation = nativeValue(GetEntityRotation, nil, vehicle, 2),
        velocity = nativeValue(GetEntityVelocity, nil, vehicle),
        bucket = nativeValue(GetEntityRoutingBucket, 0, vehicle),
        engineRunning = nativeValue(GetIsVehicleEngineRunning, false, vehicle) == true,
        properties = properties,
        persisted = stateValues.persisted,
        vehicleid = stateValues.vehicleid,
        sessionId = stateValues.sessionId,
        occupants = occupants,
        networkId = nativeValue(NetworkGetNetworkIdFromEntity, nil, vehicle),
        owner = nativeValue(NetworkGetEntityOwner, -1, vehicle),
        exactProperties = exactProperties,
        livePropertiesCaptured = false,
        deleted = false,
    }
end

local function acceptLiveProperties(attempt, netId, playerSource, properties)
    local pending = attempt.propertyPending and attempt.propertyPending[tostring(netId)]
    if not pending or pending.owner ~= playerSource or type(properties) ~= 'table' then
        return
    end

    local encodedOk, encoded = pcall(json.encode, properties)
    if encodedOk and type(encoded) == 'string' and #encoded <= 128 * 1024 then
        properties.model = pending.snapshot.model
        pending.snapshot.properties = properties
        pending.snapshot.exactProperties = true
        pending.snapshot.livePropertiesCaptured = true
    end
    attempt.propertyPending[tostring(netId)] = nil
end

RegisterNetEvent(EVENT_PREFIX .. ':server:restartVehicleProperties', function(payload)
    local playerSource = source
    if type(payload) ~= 'table' or type(payload.transactionId) ~= 'string' then return end

    local attempt
    for _, candidate in pairs(resourceRestarts) do
        if candidate.id == payload.transactionId and candidate.phase == 'snapshot' then
            attempt = candidate
            break
        end
    end
    if not attempt or type(payload.vehicles) ~= 'table' then return end

    for netId, properties in pairs(payload.vehicles) do
        acceptLiveProperties(attempt, netId, playerSource, properties)
    end
end)

local function captureResourceVehicles(attempt)
    local vehicles, listError = matchingResourceVehicles(attempt.resourceName, attempt.modelHashes)
    if not vehicles then return nil, listError end

    local requestsByOwner = {}
    for _, vehicle in ipairs(vehicles) do
        local snapshot = snapshotVehicle(vehicle)
        if snapshot then
            attempt.snapshots[#attempt.snapshots + 1] = snapshot
            attempt.snapshotsByEntity[vehicle] = snapshot
            if snapshot.networkId and snapshot.owner and snapshot.owner >= 1 then
                local netKey = tostring(snapshot.networkId)
                attempt.propertyPending[netKey] = { owner = snapshot.owner, snapshot = snapshot }
                local ownerRequests = requestsByOwner[snapshot.owner]
                if not ownerRequests then
                    ownerRequests = {}
                    requestsByOwner[snapshot.owner] = ownerRequests
                end
                ownerRequests[#ownerRequests + 1] = snapshot.networkId
            end
        end
    end

    for owner, networkIds in pairs(requestsByOwner) do
        TriggerClientEvent(EVENT_PREFIX .. ':client:captureRestartVehicles', owner, {
            transactionId = attempt.id,
            vehicles = networkIds,
        })
    end

    local deadline = GetGameTimer() + RESTART_PROPERTY_TIMEOUT_MS
    while next(attempt.propertyPending) and GetGameTimer() < deadline do
        Wait(50)
    end
    attempt.propertyPending = {}

    local inexact = 0
    for _, snapshot in ipairs(attempt.snapshots) do
        local ownerSnapshotRequired = snapshot.owner and snapshot.owner >= 1
        if (ownerSnapshotRequired and not snapshot.livePropertiesCaptured)
            or not snapshot.exactProperties
        then
            inexact = inexact + 1
        end
    end
    if inexact > 0 then
        return nil, ('Could not capture an exact live property set for %d %s vehicle(s); restart cancelled without deleting them.')
            :format(inexact, attempt.resourceName)
    end
    return true
end

local function deleteVehicleForRestart(snapshot)
    local vehicle = snapshot.originalEntity
    if not nativeValue(DoesEntityExist, false, vehicle) then return end

    snapshot.deleted = true
    if GetResourceState('qbx_core') == 'started' then
        pcall(function()
            exports.qbx_core:DisablePersistence(vehicle)
        end)
    end
    if nativeValue(DoesEntityExist, false, vehicle) and type(DeleteEntity) == 'function' then
        pcall(DeleteEntity, vehicle)
    end
end

local function removeResourceVehicles(attempt)
    local emptyConfirmations = 0
    for _ = 1, RESTART_DELETE_ATTEMPTS do
        local vehicles, listError = matchingResourceVehicles(attempt.resourceName, attempt.modelHashes)
        if not vehicles then return nil, listError end

        if #vehicles == 0 then
            emptyConfirmations = emptyConfirmations + 1
            if emptyConfirmations >= RESTART_EMPTY_CONFIRMATIONS then return true end
            Wait(RESTART_EMPTY_SETTLE_MS)
        else
            emptyConfirmations = 0
            for _, vehicle in ipairs(vehicles) do
                local snapshot = attempt.snapshotsByEntity[vehicle]
                if not snapshot then
                    return nil, ('A new %s vehicle appeared after the exact-property snapshot. Restart cancelled so it is not restored approximately.')
                        :format(attempt.resourceName)
                end
                deleteVehicleForRestart(snapshot)
            end
            Wait(RESTART_DELETE_RETRY_MS)
        end
    end

    local remaining, listError = matchingResourceVehicles(attempt.resourceName, attempt.modelHashes)
    if not remaining then return nil, listError end
    return nil, ('%d live %s vehicle(s) could not be removed safely; restart cancelled.')
        :format(#remaining, attempt.resourceName)
end

local function relevantRestorePlayers(attempt)
    local players = {}
    if type(GetPlayers) ~= 'function' or type(GetPlayerPed) ~= 'function' then
        players[attempt.playerSource] = true
        return players
    end

    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        local ped = playerSource and nativeValue(GetPlayerPed, 0, playerSource) or 0
        if ped and ped ~= 0 and nativeValue(DoesEntityExist, false, ped) then
            local pedCoords = nativeValue(GetEntityCoords, nil, ped)
            local bucket = nativeValue(GetEntityRoutingBucket, 0, ped)
            if pedCoords then
                for _, snapshot in ipairs(attempt.snapshots) do
                    if bucket == snapshot.bucket then
                        local dx = pedCoords.x - snapshot.coords.x
                        local dy = pedCoords.y - snapshot.coords.y
                        local dz = pedCoords.z - snapshot.coords.z
                        if dx * dx + dy * dy + dz * dz <= 600.0 * 600.0 then
                            players[playerSource] = true
                            break
                        end
                    end
                end
            end
        end
    end

    players[attempt.playerSource] = true
    return players
end

RegisterNetEvent(EVENT_PREFIX .. ':server:restartModelsReady', function(payload)
    local playerSource = source
    if type(payload) ~= 'table' or type(payload.transactionId) ~= 'string' then return end

    for _, attempt in pairs(resourceRestarts) do
        if attempt.id == payload.transactionId and attempt.phase == 'preloading' then
            local key = tostring(playerSource)
            if attempt.modelReadyPending and attempt.modelReadyPending[key] then
                attempt.modelReadyPending[key] = nil
                if payload.ok ~= true then
                    attempt.modelReadyFailures[#attempt.modelReadyFailures + 1] =
                        tostring(payload.error or ('client %s could not load a vehicle model'):format(playerSource))
                end
            end
            return
        end
    end
end)

local function prepareClientsForRestore(attempt)
    local models, seenModels = {}, {}
    for _, snapshot in ipairs(attempt.snapshots) do
        local key = tostring(snapshot.model)
        if not seenModels[key] then
            seenModels[key] = true
            models[#models + 1] = snapshot.model
        end
    end
    if #models == 0 then return true end

    attempt.modelReadyPending = {}
    attempt.modelReadyFailures = {}
    for playerSource in pairs(relevantRestorePlayers(attempt)) do
        if playerSource and playerSource >= 1 and nativeValue(GetPlayerPing, -1, playerSource) >= 0 then
            attempt.modelReadyPending[tostring(playerSource)] = true
            TriggerClientEvent(EVENT_PREFIX .. ':client:prepareRestartModels', playerSource, {
                transactionId = attempt.id,
                models = models,
            })
        end
    end

    local deadline = GetGameTimer() + RESTART_MODEL_READY_TIMEOUT_MS
    while next(attempt.modelReadyPending) and GetGameTimer() < deadline do
        Wait(50)
    end

    local timedOut = 0
    for _ in pairs(attempt.modelReadyPending) do timedOut = timedOut + 1 end
    attempt.modelReadyPending = {}
    if timedOut > 0 or #attempt.modelReadyFailures > 0 then
        return nil, ('Client model streaming was not ready (%d timeout(s), %d load failure(s)); vehicles were not respawned to avoid another crash.')
            :format(timedOut, #attempt.modelReadyFailures)
    end
    return true
end

RegisterNetEvent(EVENT_PREFIX .. ':server:restartVehicleApplied', function(payload)
    local playerSource = source
    if type(payload) ~= 'table'
        or type(payload.transactionId) ~= 'string'
        or type(payload.applyId) ~= 'string'
    then
        return
    end

    for _, attempt in pairs(resourceRestarts) do
        if attempt.id == payload.transactionId then
            local pending = attempt.propertyApplyPending and attempt.propertyApplyPending[payload.applyId]
            if pending and pending.owner == playerSource then
                pending.done = true
                pending.ok = payload.ok == true
                pending.error = payload.error
            end
            return
        end
    end
end)

local function applyRestartProperties(attempt, vehicle, snapshot)
    local ownershipDeadline = GetGameTimer() + 3000
    local owner = nativeValue(NetworkGetEntityOwner, -1, vehicle)
    while owner == -1 and GetGameTimer() < ownershipDeadline do
        Wait(50)
        owner = nativeValue(NetworkGetEntityOwner, -1, vehicle)
    end

    if owner ~= -1 then
        local networkId = nativeValue(NetworkGetNetworkIdFromEntity, nil, vehicle)
        if not networkId then return nil, 'the restored vehicle has no network ID' end

        local applyId = newToken('vehicle_apply')
        local pending = { owner = owner, done = false, ok = false }
        attempt.propertyApplyPending[applyId] = pending
        TriggerClientEvent(EVENT_PREFIX .. ':client:applyRestartVehicle', owner, {
            transactionId = attempt.id,
            applyId = applyId,
            networkId = networkId,
            model = snapshot.model,
            properties = snapshot.properties,
        })

        local deadline = GetGameTimer() + RESTART_PROPERTY_APPLY_TIMEOUT_MS
        while not pending.done and GetGameTimer() < deadline do Wait(50) end
        attempt.propertyApplyPending[applyId] = nil
        if pending.done and pending.ok then return true end

        -- Ownership can migrate while a resource is mounting. Falling back to
        -- ox_lib's replicated property statebag keeps the exact snapshot and
        -- applies it when the entity has a stable owner, instead of deleting
        -- the newly restored vehicle.
        if type(lib) == 'table' and type(lib.setVehicleProperties) == 'function' then
            local fallbackOk = pcall(lib.setVehicleProperties, vehicle, snapshot.properties)
            if fallbackOk then
                log(('Deferred exact properties for model %s after client apply failed: %s')
                    :format(snapshot.model, tostring(pending.error or 'owner acknowledgement timed out')))
                return true
            end
        end
        if not pending.done then return nil, 'the owning client timed out while applying vehicle properties' end
        return nil, tostring(pending.error or 'the owning client rejected vehicle properties')
    end

    -- No client is in scope. Keep the exact property set in a replicated
    -- statebag; ox_lib will apply it when a client eventually owns the entity.
    if type(lib) == 'table' and type(lib.setVehicleProperties) == 'function' then
        local ok = pcall(lib.setVehicleProperties, vehicle, snapshot.properties)
        if ok then return true end
    end
    return nil, 'no client owned the restored vehicle and its property statebag could not be created'
end

local function spawnVehicleSnapshot(attempt, snapshot)
    local coords = snapshot.coords
    local vehicle = 0
    local createdOk = pcall(function()
        if type(CreateVehicleServerSetter) == 'function' and type(snapshot.vehicleType) == 'string' then
            vehicle = CreateVehicleServerSetter(snapshot.model, snapshot.vehicleType,
                coords.x, coords.y, coords.z, snapshot.heading)
        else
            vehicle = CreateVehicle(snapshot.model, coords.x, coords.y, coords.z,
                snapshot.heading, true, true)
        end
    end)
    if not createdOk or not vehicle or vehicle == 0 then
        return nil, ('model %s could not be created'):format(snapshot.model)
    end

    local deadline = GetGameTimer() + RESTART_SPAWN_TIMEOUT_MS
    while not nativeValue(DoesEntityExist, false, vehicle) and GetGameTimer() < deadline do
        Wait(50)
    end
    if not nativeValue(DoesEntityExist, false, vehicle) then
        return nil, ('model %s did not appear before the spawn timeout'):format(snapshot.model)
    end

    -- Do not expose a half-configured entity to physics. Applying mods, damage,
    -- occupants and velocity on the same frame as model/collision streaming is
    -- both hitchy and a common cause of client crashes with large add-on packs.
    if type(FreezeEntityPosition) == 'function' then pcall(FreezeEntityPosition, vehicle, true) end
    if type(SetEntityCollision) == 'function' then pcall(SetEntityCollision, vehicle, false, false) end
    if type(SetEntityVelocity) == 'function' then pcall(SetEntityVelocity, vehicle, 0.0, 0.0, 0.0) end

    if snapshot.bucket and snapshot.bucket > 0 and type(SetEntityRoutingBucket) == 'function' then
        pcall(SetEntityRoutingBucket, vehicle, snapshot.bucket)
    end
    if type(SetEntityOrphanMode) == 'function' then pcall(SetEntityOrphanMode, vehicle, 2) end

    pcall(function()
        local state = Entity(vehicle).state
        state:set('initVehicle', true, true)
        if snapshot.vehicleid ~= nil then state:set('vehicleid', snapshot.vehicleid, false) end
        if snapshot.sessionId ~= nil then state:set('sessionId', snapshot.sessionId, true) end
    end)

    local propertiesOk, propertiesError = applyRestartProperties(attempt, vehicle, snapshot)
    if not propertiesOk then
        if type(DeleteEntity) == 'function' then pcall(DeleteEntity, vehicle) end
        return nil, ('model %s properties failed: %s'):format(snapshot.model, propertiesError)
    end

    -- qbx_core's initVehicle handler clears ambient occupants and settles the
    -- entity. Let it finish before the saved players are placed back inside.
    local initDeadline = GetGameTimer() + 1000
    while GetGameTimer() < initDeadline do
        local initializing = nativeValue(function()
            return Entity(vehicle).state.initVehicle
        end, nil)
        if not initializing then break end
        Wait(50)
    end

    if snapshot.rotation and type(SetEntityRotation) == 'function' then
        pcall(SetEntityRotation, vehicle, snapshot.rotation.x, snapshot.rotation.y, snapshot.rotation.z, 2, true)
    end

    for _, occupant in ipairs(snapshot.occupants) do
        if nativeValue(DoesEntityExist, false, occupant.ped) and type(SetPedIntoVehicle) == 'function' then
            pcall(SetPedIntoVehicle, occupant.ped, vehicle, occupant.seat)
        end
    end
    if type(SetVehicleEngineOn) == 'function' then
        pcall(SetVehicleEngineOn, vehicle, snapshot.engineRunning, true, true)
    end

    -- Persistence is deliberately enabled last. If model streaming or exact
    -- property restoration fails, Qbox cannot race us by respawning a partial
    -- duplicate from the garage database.
    if snapshot.persisted and GetResourceState('qbx_core') == 'started' then
        pcall(function() exports.qbx_core:EnablePersistence(vehicle) end)
    end
    if snapshot.vehicleid and GetResourceState('qbx_vehicles') == 'started' then
        -- Keep the garage database's mods JSON synchronized with the exact
        -- live snapshot, without changing its OUT/garage/depot state.
        pcall(function()
            exports.qbx_vehicles:SaveVehicle(vehicle, { props = snapshot.properties })
        end)
    end

    -- Never restore the old velocity onto a freshly streamed collision body.
    -- The exact transform and appearance are retained, but it is safely
    -- respawned at rest before physics/collision are released.
    if type(SetEntityVelocity) == 'function' then pcall(SetEntityVelocity, vehicle, 0.0, 0.0, 0.0) end
    if type(SetEntityCollision) == 'function' then pcall(SetEntityCollision, vehicle, true, true) end
    if type(FreezeEntityPosition) == 'function' then pcall(FreezeEntityPosition, vehicle, false) end
    local networkId = nativeValue(NetworkGetNetworkIdFromEntity, nil, vehicle)
    if networkId then
        -- SetEntityCollision is not exposed server-side on every artifact. Ask
        -- every client that streamed this entity to release its local physics
        -- state too; clients without the entity simply ignore the message.
        TriggerClientEvent(EVENT_PREFIX .. ':client:finishRestartVehicle', -1, {
            transactionId = attempt.id,
            networkId = networkId,
        })
    end

    snapshot.restoredEntity = vehicle
    return vehicle
end

local function restoreVehicleSnapshots(attempt, afterRestart)
    local restored = 0
    local errors = {}
    attempt.propertyApplyPending = {}
    for _, snapshot in ipairs(attempt.snapshots) do
        local originalStillExists = not afterRestart
            and nativeValue(DoesEntityExist, false, snapshot.originalEntity)
        if snapshot.deleted and not originalStillExists then
            local vehicle, spawnError = spawnVehicleSnapshot(attempt, snapshot)
            if vehicle then
                restored = restored + 1
            else
                errors[#errors + 1] = spawnError
            end
            Wait(RESTART_SPAWN_STAGGER_MS)
        end
    end
    attempt.propertyApplyPending = {}
    return restored, errors
end

local function finishResourceRestart(attempt, ok, message)
    if resourceRestarts[attempt.resourceName] ~= attempt then return end
    resourceRestarts[attempt.resourceName] = nil
    broadcastRestartOverlay(attempt, false, ok and 'Complete' or 'Restart failed', message)
    restartResult(attempt.playerSource, attempt, ok, ok and {
        resource = attempt.resourceName,
        message = message,
    } or {
        error = message,
    })
end

-- Runtime handling backend. The schema is server-owned: clients may report values
-- only for these native-readable fields and never choose a resource or path.
local VANILLA_SCHEMA = {
    CHandlingData = {
        floats = { 'fMass', 'fInitialDragCoeff', 'fDownforceModifier', 'fPercentSubmerged',
            'fDriveBiasFront', 'fInitialDriveForce', 'fDriveInertia', 'fClutchChangeRateScaleUpShift',
            'fClutchChangeRateScaleDownShift', 'fInitialDriveMaxFlatVel', 'fBrakeForce',
            'fBrakeBiasFront', 'fHandBrakeForce', 'fSteeringLock', 'fTractionCurveMax',
            'fTractionCurveMin', 'fTractionCurveLateral', 'fTractionSpringDeltaMax',
            'fLowSpeedTractionLossMult', 'fCamberStiffnesss', 'fTractionBiasFront',
            'fTractionLossMult', 'fSuspensionForce', 'fSuspensionCompDamp',
            'fSuspensionReboundDamp', 'fSuspensionUpperLimit', 'fSuspensionLowerLimit',
            'fSuspensionRaise', 'fSuspensionBiasFront', 'fAntiRollBarForce',
            'fAntiRollBarBiasFront', 'fRollCentreHeightFront', 'fRollCentreHeightRear',
            'fCollisionDamageMult', 'fWeaponDamageMult', 'fDeformationDamageMult',
            'fEngineDamageMult', 'fPetrolTankVolume', 'fOilVolume', 'fSeatOffsetDistX',
            'fSeatOffsetDistY', 'fSeatOffsetDistZ' },
        ints = { 'nInitialDriveGears', 'nMonetaryValue', 'strModelFlags', 'strHandlingFlags', 'strDamageFlags' },
        vectors = { 'vecCentreOfMassOffset', 'vecInertiaMultiplier' },
    },
    CCarHandlingData = { floats = { 'fBackEndPopUpCarImpulseMult', 'fBackEndPopUpBuildingImpulseMult',
        'fBackEndPopUpMaxDeltaSpeed', 'fToeFront', 'fToeRear', 'fCamberFront', 'fCamberRear',
        'fCastor', 'fEngineResistance', 'fMaxDriveBiasTransfer', 'fJumpForceScale' },
        ints = { 'strAdvancedFlags' } },
    CBikeHandlingData = { floats = { 'fLeanFwdCOMMult', 'fLeanFwdForceMult', 'fLeanBakCOMMult',
        'fLeanBakForceMult', 'fMaxBankAngle', 'fFullAnimAngle', 'fDesLeanReturnFrac',
        'fStickLeanMult', 'fBrakingStabilityMult', 'fInAirSteerMult', 'fWheelieBalancePoint',
        'fStoppieBalancePoint', 'fWheelieSteerMult', 'fRearBalanceMult', 'fFrontBalanceMult' } },
    CFlyingHandlingData = { floats = { 'fThrust', 'fThrustFallOff', 'fThrustVectoring', 'fYawMult',
        'fYawStabilise', 'fSideSlipMult', 'fRollMult', 'fRollStabilise', 'fPitchMult',
        'fPitchStabilise', 'fFormLiftMult', 'fAttackLiftMult', 'fAttackDiveMult',
        'fGearDownDragV', 'fGearDownLiftMult', 'fWindMult', 'fMoveRes', 'fTurnRes' },
        vectors = { 'vecTurnRes', 'vecSpeedRes' } },
    CBoatHandlingData = { floats = { 'fBoxFrontMult', 'fBoxRearMult', 'fBoxSideMult',
        'fSampleTop', 'fSampleBottom', 'fAquaplaneForce', 'fAquaplanePushWaterMult',
        'fAquaplanePushWaterCap', 'fAquaplanePushWaterApply', 'fRudderForce',
        'fRudderOffsetSubmerge', 'fRudderOffsetForce', 'fWaveAudioMult' } },
    CTrailerHandlingData = { floats = { 'fAttachLimitPitch', 'fAttachLimitRoll',
        'fAttachLimitYaw', 'fUprightSpringConstant', 'fUprightDampingConstant',
        'fAttachedMaxDistance', 'fAttachedMaxPenetration' } },
}

local vanilla = { ready = false, error = nil, store = nil, fields = {}, captureById = {} }
for className, kinds in pairs(VANILLA_SCHEMA) do
    for kind, names in pairs(kinds) do
        local valueType = kind == 'ints' and 'integer' or (kind == 'vectors' and 'vector' or 'number')
        for _, name in ipairs(names) do
            local id = className .. '.' .. name
            vanilla.fields[id] = { id = id, class = className, name = name, type = valueType,
                label = prettyLabel(name), live = true, restartRequired = false }
        end
    end
end

local function vanillaConfig()
    return type(CHandlingEditorConfig) == 'table' and CHandlingEditorConfig.vanilla or nil
end

local function validateVanillaStore(raw)
    local ok, decoded = pcall(json.decode, raw or '')
    if not ok or type(decoded) ~= 'table' then return nil, 'The vanilla handling JSON is malformed.' end
    if decoded.schemaVersion ~= 1 or type(decoded.models) ~= 'table' or type(decoded.revision) ~= 'number' then
        return nil, 'The vanilla handling JSON does not match schema version 1.'
    end
    local cfg = vanillaConfig()
    if decoded.gameBuild ~= cfg.gameBuild then
        return nil, ('Vanilla handling store build %s does not match configured build %s.')
            :format(tostring(decoded.gameBuild), tostring(cfg.gameBuild))
    end
    if decoded.revision < 0 or decoded.revision % 1 ~= 0 then
        return nil, 'The vanilla handling store revision is invalid.'
    end
    for hashKey, model in pairs(decoded.models) do
        local hash = normalizeHash(hashKey)
        if not hash or tostring(hash) ~= tostring(hashKey) or type(model) ~= 'table'
            or type(model.baseline) ~= 'table' or type(model.overrides) ~= 'table'
            or type(model.revision) ~= 'number' or model.revision < 0 or model.revision % 1 ~= 0
        then
            return nil, ('The vanilla handling model entry %s is invalid.'):format(tostring(hashKey))
        end
        for _, values in ipairs({ model.baseline, model.overrides }) do
            for id, value in pairs(values) do
                local field = vanilla.fields[id]
                if not field or validateFieldValue(field, value) == nil then
                    return nil, ('The vanilla handling field %s in model %s is invalid.')
                        :format(tostring(id), hashKey)
                end
            end
        end
    end
    return decoded
end

local function loadVanillaStore()
    vanilla.ready, vanilla.error, vanilla.store = false, nil, nil
    local cfg = vanillaConfig()
    if not cfg or cfg.enabled ~= true then vanilla.error = 'The vanilla runtime backend is disabled.' return false end
    if type(cfg.resource) ~= 'string' or cfg.resource == '' or type(cfg.file) ~= 'string'
        or not normalizeResourcePath(cfg.file, false) or cfg.file:sub(1, 1) == '/' then
        vanilla.error = 'The vanilla runtime resource or relative JSON path is invalid.' return false
    end
    if GetResourceState(cfg.resource) ~= 'started' then
        vanilla.error = ('Storage resource %s is not started. Start it before %s.'):format(cfg.resource, RESOURCE_NAME)
        return false
    end
    local enforced = GetConvarInt('sv_enforceGameBuild', 0)
    if enforced ~= cfg.gameBuild then
        vanilla.error = ('sv_enforceGameBuild must be %d (currently %d).'):format(cfg.gameBuild, enforced)
        return false
    end
    local store, err = validateVanillaStore(LoadResourceFile(cfg.resource, cfg.file))
    if not store then vanilla.error = err return false end
    vanilla.store, vanilla.ready = store, true
    return true
end

local function vanillaGroups(capture)
    local grouped, order = {}, {}
    for id, value in pairs(capture) do
        local schema = vanilla.fields[id]
        if schema then
            local group = grouped[schema.class]
            if not group then
                group = { name = schema.class, label = prettyClassName(schema.class), fields = {} }
                grouped[schema.class] = group; order[#order + 1] = group
            end
            local field = copyValue(schema); field.value = copyValue(value); field.originalValue = copyValue(value)
            field.currentValue = copyValue(value); group.fields[#group.fields + 1] = field
        end
    end
    table.sort(order, function(a, b) return a.name < b.name end)
    for _, group in ipairs(order) do table.sort(group.fields, function(a, b) return a.name < b.name end) end
    return order
end

local function requestVanillaCapture(playerSource, payload, actualHash)
    if not vanilla.ready and not loadVanillaStore() then notify(playerSource, vanilla.error, 'error') return end
    local token = newToken('capture')
    pendingVanillaCaptures[playerSource] = { token = token, modelHash = actualHash,
        modelName = safeDisplayText(payload.modelName, ('0x%08X'):format(actualHash)),
        displayName = safeDisplayText(payload.displayName, payload.modelName), expiresAt = nowSeconds() + REQUEST_TTL_SECONDS }
    TriggerClientEvent(EVENT_PREFIX .. ':client:captureVanilla', playerSource, {
        token = token, modelHash = actualHash, schema = VANILLA_SCHEMA,
    })
end

RegisterNetEvent(EVENT_PREFIX .. ':server:vanillaCapture', function(payload)
    local playerSource = source
    local pending = pendingVanillaCaptures[playerSource]
    pendingVanillaCaptures[playerSource] = nil
    if type(payload) ~= 'table' or not pending or payload.token ~= pending.token or pending.expiresAt < nowSeconds() then return end
    local actualHash = actualDrivenVehicleModel(playerSource)
    if actualHash ~= pending.modelHash then notify(playerSource, 'The vehicle changed during handling capture.', 'error') return end
    local captured = {}
    if type(payload.fields) == 'table' then
        for id, value in pairs(payload.fields) do
            local field = vanilla.fields[id]
            if field then
                local normalized = validateFieldValue(field, value)
                if normalized ~= nil then captured[id] = normalized end
            end
        end
    end
    local count = 0; for _ in pairs(captured) do count = count + 1 end
    if count == 0 then notify(playerSource, 'This runtime exposed no safely round-trippable handling fields.', 'error') return end
    local stored = vanilla.store.models[tostring(actualHash)]
    local effective = copyValue(captured)
    if stored and type(stored.overrides) == 'table' then
        for id, value in pairs(stored.overrides) do if vanilla.fields[id] then effective[id] = copyValue(value) end end
    end
    local groups = vanillaGroups(effective)
    local fields = {}; for _, group in ipairs(groups) do for _, field in ipairs(group.fields) do fields[field.id] = field end end
    local sessionId = newToken('session')
    sessions[playerSource] = { id = sessionId, backend = 'vanilla_runtime', expiresAt = nowSeconds() + SESSION_TTL_SECONDS,
        modelHash = actualHash, modelName = pending.modelName, resource = vanillaConfig().resource,
        handlingPath = vanillaConfig().file, fields = fields, capture = captured,
        modelRevision = stored and stored.revision or 0 }
    TriggerClientEvent(EVENT_PREFIX .. ':client:open', playerSource, { sessionId = sessionId,
        canEdit = canPlayerEdit(playerSource), vehicle = { modelHash = actualHash, modelName = pending.modelName,
            displayName = pending.displayName }, handling = { name = pending.modelName, resource = vanillaConfig().resource,
            path = vanillaConfig().file, backend = 'vanilla_runtime', restartSupported = false }, groups = groups })
end)

local function syncVanilla(target)
    if not vanilla.ready then return end
    TriggerClientEvent(EVENT_PREFIX .. ':client:vanillaSync', target or -1, {
        revision = vanilla.store.revision, models = vanilla.store.models, fields = vanilla.fields,
    })
end

RegisterNetEvent(EVENT_PREFIX .. ':server:requestVanillaSync', function()
    if not vanilla.ready then loadVanillaStore() end
    syncVanilla(source)
end)

local function saveVanillaField(playerSource, payload, session, field, newValue, expectedValue)
    local cfg = vanillaConfig()
    enqueueFileTask(cfg.resource, cfg.file, function()
        if sessions[playerSource] ~= session or actualDrivenVehicleModel(playerSource) ~= session.modelHash then
            saveResult(playerSource, payload, false, { error = 'The vanilla session or driver vehicle changed.' }); return
        end
        local raw = LoadResourceFile(cfg.resource, cfg.file)
        local store, loadError = validateVanillaStore(raw)
        if not store then vanilla.ready = false; vanilla.error = loadError; saveResult(playerSource, payload, false, { error = loadError }); return end
        local key = tostring(session.modelHash); local model = store.models[key]
        local current = model and model.overrides and model.overrides[field.id]
        if current == nil then current = session.capture[field.id] end
        if not valueEquals(current, expectedValue, field.type) then
            field.currentValue = copyValue(current)
            saveResult(playerSource, payload, false, { error = 'This runtime override changed after the editor was opened.',
                conflict = true, value = copyValue(current), restartRequired = false }); return
        end
        if not model then
            model = { modelName = session.modelName, captureVersion = 1, revision = 0,
                baseline = copyValue(session.capture), overrides = {} }; store.models[key] = model
        end
        model.overrides[field.id] = copyValue(newValue); model.revision = (model.revision or 0) + 1
        store.revision = store.revision + 1
        local encoded = json.encode(store)
        if not SaveResourceFile(cfg.resource, cfg.file .. '.cHandlingEditor.bak', raw, #raw) then
            saveResult(playerSource, payload, false, { error = permissionSuggestion(cfg.resource) }); return
        end
        if not SaveResourceFile(cfg.resource, cfg.file, encoded, #encoded) then
            saveResult(playerSource, payload, false, { error = permissionSuggestion(cfg.resource) }); return
        end
        local confirmed, confirmError = validateVanillaStore(LoadResourceFile(cfg.resource, cfg.file))
        if not confirmed or confirmed.revision ~= store.revision then
            saveResult(playerSource, payload, false, { error = confirmError or 'The runtime store write could not be confirmed.' }); return
        end
        vanilla.store = confirmed; vanilla.ready = true; field.currentValue = copyValue(newValue)
        saveResult(playerSource, payload, true, { value = copyValue(newValue), restartRequired = false })
        syncVanilla(-1)
    end, function() saveResult(playerSource, payload, false, { error = 'An unexpected runtime-store error interrupted this save.' }) end)
end

RegisterCommand('handlingeditor', function(playerSource)
    if playerSource == 0 then
        log('/handlingeditor can only be used by an in-game player.')
        return
    end

    if not canPlayerView(playerSource) then
        notify(playerSource, ('Access denied: missing ACE %s (or admin compatibility ACE).'):format(VIEW_ACE), 'error')
        return
    end
    if not activeIndex.ready or scanRunning then
        notify(playerSource, 'Vehicle metadata is still being indexed. Try again in a moment.', 'warning')
        return
    end

    sessions[playerSource] = nil
    local requestId = newToken('inspect')
    pendingInspections[playerSource] = {
        requestId = requestId,
        expiresAt = nowSeconds() + REQUEST_TTL_SECONDS,
    }
    TriggerClientEvent(EVENT_PREFIX .. ':client:requestVehicle', playerSource, {
        requestId = requestId,
    })
end, false)

RegisterNetEvent(EVENT_PREFIX .. ':server:inspectVehicle', function(payload)
    local playerSource = source
    if type(payload) ~= 'table' then
        return
    end

    local pending = pendingInspections[playerSource]
    if not pending then
        notify(playerSource, 'The handling-editor request expired. Run /handlingeditor again.', 'error')
        return
    end
    if pending.expiresAt < nowSeconds() then
        pendingInspections[playerSource] = nil
        notify(playerSource, 'The handling-editor request expired. Run /handlingeditor again.', 'error')
        return
    end
    -- A delayed response for an older command must not consume the newer
    -- one-time token currently pending for this player.
    if type(payload.requestId) ~= 'string' or payload.requestId ~= pending.requestId then
        return
    end
    pendingInspections[playerSource] = nil

    if not canPlayerView(playerSource) then
        notify(playerSource, ('Access denied: missing ACE %s (or admin compatibility ACE).'):format(VIEW_ACE), 'error')
        return
    end

    if payload.error then
        if payload.error == 'not_driver' then
            notify(playerSource, 'Only the driver can open the handling editor.', 'error')
        elseif payload.error == 'not_in_vehicle' or payload.error == 'vehicle_missing' then
            notify(playerSource, 'You must be driving an add-on vehicle to use the handling editor.', 'error')
        else
            notify(playerSource, 'The client could not inspect the current vehicle.', 'error')
        end
        return
    end

    local actualHash, vehicleError = actualDrivenVehicleModel(playerSource)
    if not actualHash then
        notify(playerSource, vehicleError, 'error')
        return
    end

    local reportedHash = normalizeHash(payload.modelHash)
    if not reportedHash or reportedHash ~= actualHash then
        notify(playerSource, 'The vehicle changed while the editor was opening. Run /handlingeditor again.', 'error')
        return
    end

    local record, recordError = selectModelRecord(actualHash)
    if not record then
        if #(activeIndex.unresolvedModels[tostring(actualHash)] or {}) == 0
            and #(activeIndex.models[tostring(actualHash)] or {}) == 0
        then
            requestVanillaCapture(playerSource, payload, actualHash)
            return
        end
        notify(playerSource, recordError, 'error')
        return
    end

    local xml, loadError = loadXml(record.resource, record.handlingPath)
    if not xml then
        notify(playerSource, loadError, 'error')
        return
    end
    local entryNode, entryError = findUniqueHandlingEntry(xml, record.handlingName)
    if not entryNode then
        notify(playerSource, entryError, 'error')
        scheduleIndexScan(0)
        return
    end

    local groups, fieldsById, fieldCount = buildFields(xml, entryNode)
    if fieldCount == 0 then
        notify(playerSource, 'No editable scalar, vector, or text fields were found in this handling entry.', 'error')
        return
    end

    local sessionId = newToken('session')
    local canEdit = canPlayerEdit(playerSource)
    sessions[playerSource] = {
        id = sessionId,
        expiresAt = nowSeconds() + SESSION_TTL_SECONDS,
        modelHash = actualHash,
        modelName = record.modelName,
        resource = record.resource,
        handlingPath = record.handlingPath,
        handlingName = record.handlingName,
        fields = fieldsById,
    }

    if not canEdit then
        -- View-only principals are supported intentionally. This message also
        -- gives operators an exact diagnosis when an expected admin grant was
        -- added on disk but permissions.cfg was not re-executed at runtime.
        notify(playerSource,
            ('This account has view-only access; the server denied %s and the admin compatibility ACE. If this is unexpected, ask an operator to check the FXServer console.')
                :format(EDIT_ACE),
            'warning')
        log(('Player %s opened a view-only session. Diagnose with `test_ace player.%s %s`, '
            .. '`test_ace player.%s %s`, and `test_ace group.admin %s`; apply current cfg with `exec permissions.cfg`.')
            :format(playerSource, playerSource, EDIT_ACE, playerSource, ADMIN_COMPAT_ACE, EDIT_ACE))
    end

    TriggerClientEvent(EVENT_PREFIX .. ':client:open', playerSource, {
        sessionId = sessionId,
        canEdit = canEdit,
        vehicle = {
            modelHash = actualHash,
            modelName = record.modelName,
            displayName = safeDisplayText(payload.displayName,
                safeDisplayText(record.displayName, record.modelName)),
        },
        handling = {
            name = record.handlingName,
            resource = record.resource,
            path = record.handlingPath,
        },
        groups = groups,
    })
end)

RegisterNetEvent(EVENT_PREFIX .. ':server:closeSession', function(payload)
    local playerSource = source
    local sessionId = type(payload) == 'table' and payload.sessionId or payload
    local session = sessions[playerSource]
    if session and type(sessionId) == 'string' and session.id == sessionId then
        sessions[playerSource] = nil
    end
end)

RegisterNetEvent(EVENT_PREFIX .. ':server:saveField', function(payload)
    local playerSource = source
    if type(payload) ~= 'table' then
        return
    end

    if not canPlayerEdit(playerSource) then
        saveResult(playerSource, payload, false, {
            error = ('Access denied: missing ACE %s (or admin compatibility ACE).'):format(EDIT_ACE),
        })
        return
    end

    local session = sessions[playerSource]
    if not session
        or type(payload.sessionId) ~= 'string'
        or payload.sessionId ~= session.id
        or session.expiresAt < nowSeconds()
    then
        sessions[playerSource] = nil
        saveResult(playerSource, payload, false, { error = 'The editor session expired. Reopen it and try again.' })
        return
    end

    if type(payload.fieldId) ~= 'string' or #payload.fieldId > 160 then
        saveResult(playerSource, payload, false, { error = 'That field is not part of this session.' })
        return
    end
    local field = session.fields[payload.fieldId]
    if not field then
        saveResult(playerSource, payload, false, { error = 'That field is not part of this session.' })
        return
    end
    if payload.expectedValue == nil then
        saveResult(playerSource, payload, false, { error = 'The save request is missing its expected value.' })
        return
    end

    local currentModel, vehicleError = actualDrivenVehicleModel(playerSource)
    if not currentModel or currentModel ~= session.modelHash then
        sessions[playerSource] = nil
        saveResult(playerSource, payload, false, {
            error = vehicleError or 'You are no longer driving the vehicle attached to this editor session.',
        })
        return
    end

    local newValue, validationError = validateFieldValue(field, payload.value)
    if newValue == nil then
        saveResult(playerSource, payload, false, { error = validationError })
        return
    end

    local expectedValue, expectedError = validateFieldValue(field, payload.expectedValue)
    if expectedValue == nil then
        saveResult(playerSource, payload, false, { error = expectedError or 'The expected value is invalid.' })
        return
    end
    if not valueEquals(field.currentValue, expectedValue, field.type) then
        saveResult(playerSource, payload, false, {
            error = 'This field changed after the editor was opened. Refresh before overwriting it.',
            conflict = true,
            value = copyValue(field.currentValue),
            restartRequired = not field.live,
        })
        return
    end

    if session.backend == 'vanilla_runtime' then
        session.expiresAt = nowSeconds() + SESSION_TTL_SECONDS
        saveVanillaField(playerSource, payload, session, field, newValue, expectedValue)
        return
    end

    session.expiresAt = nowSeconds() + SESSION_TTL_SECONDS
    enqueueFileTask(session.resource, session.handlingPath, function()
        local currentSession = sessions[playerSource]
        if currentSession ~= session or currentSession.id ~= payload.sessionId then
            saveResult(playerSource, payload, false, { error = 'The editor session closed before the save ran.' })
            return
        end
        if not canPlayerEdit(playerSource) then
            saveResult(playerSource, payload, false, {
                error = ('Access denied: missing ACE %s (or admin compatibility ACE).'):format(EDIT_ACE),
            })
            return
        end
        local queuedModel, queuedVehicleError = actualDrivenVehicleModel(playerSource)
        if not queuedModel or queuedModel ~= session.modelHash then
            if sessions[playerSource] == session then
                sessions[playerSource] = nil
            end
            saveResult(playerSource, payload, false, {
                error = queuedVehicleError or 'You are no longer driving the vehicle attached to this editor session.',
            })
            return
        end
        if not modelRecordStillMapped(session) then
            saveResult(playerSource, payload, false, {
                error = 'The vehicle metadata mapping changed. Reopen the editor before saving.',
                conflict = true,
            })
            return
        end

        local xml, loadError = loadXml(session.resource, session.handlingPath)
        if not xml then
            saveResult(playerSource, payload, false, { error = loadError })
            return
        end
        local entryNode, entryError = findUniqueHandlingEntry(xml, session.handlingName)
        if not entryNode then
            saveResult(playerSource, payload, false, { error = entryError, conflict = true })
            return
        end

        local node = resolveLocator(entryNode, field.locator)
        local descriptor = node and describeLeaf(xml, node, field.class) or nil
        if not descriptor
            or descriptor.name ~= field.name
            or descriptor.class ~= field.class
            or descriptor.type ~= field.type
        then
            saveResult(playerSource, payload, false, {
                error = 'The field structure changed on disk. Reopen the editor before saving.',
                conflict = true,
            })
            return
        end

        if not valueEquals(descriptor.value, expectedValue, field.type) then
            field.currentValue = copyValue(descriptor.value)
            saveResult(playerSource, payload, false, {
                error = 'This field changed on disk. Refresh before overwriting it.',
                conflict = true,
                value = copyValue(descriptor.value),
                restartRequired = not field.live,
            })
            return
        end

        if valueEquals(descriptor.value, newValue, field.type) then
            -- Even a no-op returns the file's parsed representation so the
            -- client and subsequent expected-value checks share one canonical
            -- value (including normalized -0/number representations).
            field.currentValue = copyValue(descriptor.value)
            saveResult(playerSource, payload, true, {
                value = copyValue(descriptor.value),
                restartRequired = not field.live,
            })
            return
        end

        local updated, patchError = applyReplacements(xml, replacementsForValue(descriptor, newValue))
        if not updated then
            saveResult(playerSource, payload, false, { error = patchError, conflict = true })
            return
        end

        local reparsedEntry, reparseError = findUniqueHandlingEntry(updated, session.handlingName)
        if not reparsedEntry then
            saveResult(playerSource, payload, false, {
                error = 'The proposed value would make the handling XML invalid: ' .. tostring(reparseError),
            })
            return
        end


        local persistedNode = resolveLocator(reparsedEntry, field.locator)
        local persistedDescriptor = persistedNode
            and describeLeaf(updated, persistedNode, field.class)
            or nil
        if not persistedDescriptor
            or persistedDescriptor.name ~= field.name
            or persistedDescriptor.class ~= field.class
            or persistedDescriptor.type ~= field.type
        then
            saveResult(playerSource, payload, false, {
                error = 'The formatted value did not resolve back to the same handling field.',
                conflict = true,
            })
            return
        end
        local persistedValue = copyValue(persistedDescriptor.value)

        local saved, saveError = saveWithBackup(session.resource, session.handlingPath, xml, updated)
        if not saved then
            saveResult(playerSource, payload, false, { error = saveError })
            return
        end

        -- Numeric formatting may round to the precision already used by the XML.
        -- Store and return the exact re-parsed value that was persisted so the
        -- client's canonical/live value and the next stale check stay aligned.
        field.currentValue = copyValue(persistedValue)
        saveResult(playerSource, payload, true, {
            value = copyValue(persistedValue),
            restartRequired = not field.live,
        })
    end, function()
        -- This callback is created only after the source/session/field have been
        -- validated. It correlates the original request without accepting any
        -- resource, path, or field authority from a subsequent client payload.
        saveResult(playerSource, payload, false, {
            error = 'An unexpected server error interrupted this save. The file was not confirmed as saved; retry or check the server console.',
        })
    end)
end)

RegisterNetEvent(EVENT_PREFIX .. ':server:restartResource', function(payload)
    local playerSource = source
    if type(payload) ~= 'table' then
        return
    end
    if not canPlayerEdit(playerSource) then
        restartResult(playerSource, payload, false, {
            error = ('Access denied: missing ACE %s (or admin compatibility ACE).'):format(EDIT_ACE),
        })
        return
    end

    local session = sessions[playerSource]
    if not session
        or type(payload.sessionId) ~= 'string'
        or payload.sessionId ~= session.id
        or session.expiresAt < nowSeconds()
    then
        sessions[playerSource] = nil
        restartResult(playerSource, payload, false, { error = 'The editor session expired. Reopen it and try again.' })
        return
    end
    if session.backend == 'vanilla_runtime' then
        restartResult(playerSource, payload, false, {
            error = 'Runtime handling overrides are applied live and cannot restart a resource.',
        })
        return
    end
    if not modelRecordStillMapped(session) then
        restartResult(playerSource, payload, false, {
            error = 'The vehicle resource mapping changed. Reopen the editor before restarting it.',
        })
        return
    end


    local currentModel, vehicleError = actualDrivenVehicleModel(playerSource)
    if not currentModel or currentModel ~= session.modelHash then
        sessions[playerSource] = nil
        restartResult(playerSource, payload, false, {
            error = vehicleError or 'You are no longer driving the vehicle attached to this editor session.',
        })
        return
    end

    local resourceName = session.resource
    if resourceName == RESOURCE_NAME
        or not resourceName:match('^[%w_.-]+$')
        or GetResourceState(resourceName) ~= 'started'
    then
        restartResult(playerSource, payload, false, { error = 'The mapped vehicle resource cannot be restarted safely.' })
        return
    end

    local restartBlockedReason = GetResourceMetadata(
        resourceName, 'chandling_restart_blocked', 0)
    if type(restartBlockedReason) == 'string' and trim(restartBlockedReason) ~= '' then
        restartResult(playerSource, payload, false, {
            error = trim(restartBlockedReason),
        })
        return
    end

    for activeResource in pairs(resourceRestarts) do
        restartResult(playerSource, payload, false, {
            error = ('A guarded vehicle restart is already in progress for %s.'):format(activeResource),
        })
        return
    end

    sessions[playerSource] = nil
    local restartAttempt = {
        id = newToken('resource_restart'),
        requestId = safeRequestId(payload.requestId),
        playerSource = playerSource,
        resourceName = resourceName,
        modelHashes = resourceModelHashes(resourceName),
        snapshots = {},
        snapshotsByEntity = {},
        propertyPending = {},
        phase = 'snapshot',
    }
    resourceRestarts[resourceName] = restartAttempt
    broadcastRestartOverlay(restartAttempt, true, 'Preparing restart',
        ('Capturing every live %s vehicle exactly as it is.'):format(resourceName))

    CreateThread(function()
        local captureOk, captured, captureError = pcall(captureResourceVehicles, restartAttempt)
        if resourceRestarts[resourceName] ~= restartAttempt then return end
        if not captureOk or not captured then
            finishResourceRestart(restartAttempt, false, captureOk and captureError
                or 'Vehicle snapshotting failed unexpectedly; nothing was restarted.')
            if not captureOk then log(('Snapshot failure for %s: %s'):format(resourceName, tostring(captured))) end
            return
        end

        restartAttempt.phase = 'cleanup'
        broadcastRestartOverlay(restartAttempt, true, 'Securing vehicles',
            ('Saving tuning, colors, plates and garage identity for %d vehicle(s).')
                :format(#restartAttempt.snapshots))

        local cleanupCallOk, cleanupOk, cleanupError = pcall(removeResourceVehicles, restartAttempt)
        if resourceRestarts[resourceName] ~= restartAttempt then return end
        if not cleanupCallOk or not cleanupOk then
            broadcastRestartOverlay(restartAttempt, true, 'Rolling back',
                'Cleanup could not be verified. Restoring any vehicles already removed.')
            local restored, restoreErrors = restoreVehicleSnapshots(restartAttempt, false)
            local reason = cleanupCallOk and cleanupError
                or 'Vehicle cleanup failed unexpectedly; the resource was not restarted.'
            if #restoreErrors > 0 then
                reason = reason .. (' Rollback restored %d vehicle(s), but %d failed; check the server console.')
                    :format(restored, #restoreErrors)
                log(('Rollback errors for %s: %s'):format(resourceName, table.concat(restoreErrors, '; ')))
            end
            finishResourceRestart(restartAttempt, false, reason)
            return
        end

        restartAttempt.phase = 'awaiting_stop'
        broadcastRestartOverlay(restartAttempt, true, 'Restarting vehicle pack',
            ('All %d vehicle(s) are safely stored. Reloading %s now.')
                :format(#restartAttempt.snapshots, resourceName))

        -- ExecuteCommand is deliberately limited to the server-resolved resource.
        -- permissions.cfg grants restart plus the stop/start checks performed
        -- internally by FXServer's restart command.
        ExecuteCommand('restart ' .. resourceName)

        SetTimeout(RESTART_COMMAND_TIMEOUT_MS, function()
            if resourceRestarts[resourceName] ~= restartAttempt
                or restartAttempt.phase ~= 'awaiting_stop'
            then
                return
            end

            broadcastRestartOverlay(restartAttempt, true, 'Rolling back',
                'The restart command was rejected. Restoring the saved vehicles.')
            local restored, restoreErrors = restoreVehicleSnapshots(restartAttempt, false)
            if #restoreErrors > 0 then
                log(('Command rollback errors for %s: %s'):format(resourceName, table.concat(restoreErrors, '; ')))
            end
            finishResourceRestart(restartAttempt, false,
                ('The restart command did not stop %s. Restored %d/%d vehicle(s). Check command.restart, command.stop and command.start ACEs.')
                    :format(resourceName, restored, #restartAttempt.snapshots))
        end)
    end)
end)

AddEventHandler('playerDropped', function()
    local playerSource = source
    pendingInspections[playerSource] = nil
    sessions[playerSource] = nil

    -- A disconnect must not make an in-flight staged restore wait for its full
    -- model/property timeout. Ownership can then migrate or fail immediately.
    for _, attempt in pairs(resourceRestarts) do
        if attempt.modelReadyPending then
            attempt.modelReadyPending[tostring(playerSource)] = nil
        end
        for _, pending in pairs(attempt.propertyApplyPending or {}) do
            if pending.owner == playerSource and not pending.done then
                pending.done = true
                pending.ok = false
                pending.error = 'the owning client disconnected during property restoration'
            end
        end
    end
end)

AddEventHandler('onResourceStart', function(resourceName)
    local cfg = vanillaConfig()
    if cfg and resourceName == cfg.resource then
        loadVanillaStore()
        syncVanilla(-1)
    end
    if not resourceHasVehicleMetadata(resourceName) then return end
    scheduleIndexScan(500)
end)

AddEventHandler('onServerResourceStart', function(resourceName)
    local restartAttempt = resourceRestarts[resourceName]
    if not restartAttempt or restartAttempt.phase ~= 'awaiting_start' then return end

    restartAttempt.phase = 'preloading'
    broadcastRestartOverlay(restartAttempt, true, 'Streaming vehicle models',
        ('%s is online. Loading vehicle assets safely before any entity is recreated.')
            :format(resourceName))

    CreateThread(function()
        -- Give the resource data-file mounters and stream cache a quiet window
        -- before clients are asked to load models from the restarted pack.
        Wait(RESTART_POST_START_SETTLE_MS)
        if resourceRestarts[resourceName] ~= restartAttempt then return end

        local prepareCallOk, prepared, prepareError = pcall(prepareClientsForRestore, restartAttempt)
        if resourceRestarts[resourceName] ~= restartAttempt then return end
        if not prepareCallOk or not prepared then
            local reason = prepareCallOk and prepareError
                or 'Client model preloading failed unexpectedly.'
            log(('Model preload warning for %s: %s Continuing with staged restore and replicated properties.')
                :format(resourceName, tostring(prepareCallOk and reason or prepared)))
            broadcastRestartOverlay(restartAttempt, true, 'Finalizing vehicle streaming',
                'A client did not confirm preload in time. Restoring the saved vehicles with the safe replicated fallback.')
            Wait(750)
            if resourceRestarts[resourceName] ~= restartAttempt then return end
        end

        restartAttempt.phase = 'restoring'
        broadcastRestartOverlay(restartAttempt, true, 'Restoring vehicles',
            ('Models are ready. Recreating %d vehicle(s) one at a time with exact properties.')
                :format(#restartAttempt.snapshots))

        local restoreCallOk, restored, restoreErrors = pcall(restoreVehicleSnapshots, restartAttempt, true)
        if not restoreCallOk then
            log(('Restore failure for %s: %s'):format(resourceName, tostring(restored)))
            finishResourceRestart(restartAttempt, false,
                ('%s restarted, but vehicle restoration failed unexpectedly. Check the server console.')
                    :format(resourceName))
            return
        end
        if #restoreErrors > 0 then
            log(('Restore errors for %s: %s'):format(resourceName, table.concat(restoreErrors, '; ')))
            finishResourceRestart(restartAttempt, false,
                ('%s restarted, but only %d/%d vehicle(s) were restored. Check the server console.')
                    :format(resourceName, restored, #restartAttempt.snapshots))
            return
        end

        -- Let the final network entity/collision update settle before players
        -- are unfrozen and the loading overlay is removed.
        Wait(350)
        finishResourceRestart(restartAttempt, true,
            ('%s restarted and restored %d vehicle(s) with their original properties and occupants.')
                :format(resourceName, restored))
    end)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == RESOURCE_NAME then
        return
    end

    local cfg = vanillaConfig()
    if cfg and resourceName == cfg.resource then
        vanilla.ready, vanilla.store = false, nil
        vanilla.error = ('Storage resource %s stopped.'):format(resourceName)
        TriggerClientEvent(EVENT_PREFIX .. ':client:vanillaSync', -1, {
            revision = 0, models = {}, fields = vanilla.fields,
        })
    end


    local restartAttempt = resourceRestarts[resourceName]
    if restartAttempt then
        if restartAttempt.phase == 'awaiting_stop' then
            restartAttempt.phase = 'awaiting_start'
            SetTimeout(RESTART_START_TIMEOUT_MS, function()
                if resourceRestarts[resourceName] ~= restartAttempt
                    or restartAttempt.phase ~= 'awaiting_start'
                then
                    return
                end
                finishResourceRestart(restartAttempt, false,
                    ('%s stopped but did not start again. Its %d saved vehicle snapshot(s) could not be recreated yet.')
                        :format(resourceName, #restartAttempt.snapshots))
            end)
        elseif restartAttempt.phase ~= 'awaiting_start' then
            finishResourceRestart(restartAttempt, false,
                ('%s stopped unexpectedly during the guarded restart.'):format(resourceName))
        end
    end

    invalidateSessionsForResource(resourceName, 'resource_stopped')
    if not resourceHasVehicleMetadata(resourceName) then return end
    scheduleIndexScan(250)
end)

CreateThread(function()
    Wait(0)
    auditAdminAceConfiguration()
    scheduleIndexScan(0)

    while true do
        Wait(60000)
        local currentTime = nowSeconds()
        for playerSource, pending in pairs(pendingInspections) do
            if pending.expiresAt < currentTime then
                pendingInspections[playerSource] = nil
            end
        end
        for playerSource, pending in pairs(pendingVanillaCaptures) do
            if pending.expiresAt < currentTime then pendingVanillaCaptures[playerSource] = nil end
        end
        for playerSource, session in pairs(sessions) do
            if session.expiresAt < currentTime then
                sessions[playerSource] = nil
                TriggerClientEvent(EVENT_PREFIX .. ':client:close', playerSource, { reason = 'session_expired' })
            end
        end
    end
end)
