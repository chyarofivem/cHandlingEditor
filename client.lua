--[[
    cHandlingEditor client/server contract

    server -> client  cHandlingEditor:client:requestVehicle { requestId }
    client -> server  cHandlingEditor:server:inspectVehicle {
        requestId, modelHash, modelName, displayName, plate
    }
    server -> client  cHandlingEditor:client:open {
        sessionId, canEdit, vehicle, handling, groups
    }
    client -> server  cHandlingEditor:server:saveField {
        requestId, sessionId, fieldId, value, expectedValue
    }
    server -> client  cHandlingEditor:client:saveResult {
        requestId, fieldId, ok, value?, error?, conflict?, restartRequired?
    }
    client -> server  cHandlingEditor:server:closeSession { sessionId }
    client -> server  cHandlingEditor:server:restartResource { requestId, sessionId }
    server -> client  cHandlingEditor:client:restartResult { requestId, ok, error? }
    server -> client  cHandlingEditor:client:notify { message, type? }

    Entity handles never leave this client. The server independently verifies the
    player's current vehicle, driver seat, model, session, field, and ACE rights.
]]

local RESOURCE_NAME = GetCurrentResourceName()
local EVENT_PREFIX = 'cHandlingEditor'
local LIVE_FLOAT_ABSOLUTE_TOLERANCE = 0.0001
local LIVE_FLOAT_RELATIVE_TOLERANCE = 0.00001
local RESTART_REQUEST_TIMEOUT_MS = 120000
local RESTART_MODEL_LOAD_TIMEOUT_MS = 10500
local RESTART_COLLISION_GRACE_MS = 1250
local RESTART_ENTITY_APPEAR_TIMEOUT_MS = 4000
local RESTART_CONTROL_TIMEOUT_MS = 1250

local editor = {
    open = false,
    sessionId = nil,
    canEdit = false,
    vehicle = 0,
    modelHash = nil,
    fields = {},
}

local requestCounter = 0
local pendingSaves = {}
local pendingByField = {}
local pendingRestartId = nil
local activeRestartOverlayId = nil
local restartFreezeApplied = false
local restartLoadedModels = {}
local vanillaOverrides = {}
local vanillaFields = {}
local vanillaApplied = {}

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

local function finiteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function parseFiniteNumber(value)
    if type(value) == 'string' then
        if value:match('^%s*$') then
            return nil
        end
    elseif type(value) ~= 'number' then
        return nil
    end

    local parsed = tonumber(value)
    return finiteNumber(parsed) and parsed or nil
end

local function resolveRestartRequired(serverValue, liveWarning)
    if liveWarning then
        return true
    elseif serverValue ~= nil then
        return serverValue == true
    end
    return nil
end

local function notify(message, notificationType)
    local normalizedType = type(notificationType) == 'string' and string.lower(notificationType) or 'info'
    if normalizedType == 'inform' then
        normalizedType = 'info'
    elseif normalizedType ~= 'info'
        and normalizedType ~= 'warning'
        and normalizedType ~= 'success'
        and normalizedType ~= 'error'
    then
        normalizedType = 'info'
    end

    lib.notify({
        title = 'cHandlingEditor',
        description = tostring(message or 'Unknown error'),
        type = normalizedType,
        position = 'center-left',
        duration = 5000,
    })
end

local function nextRequestId(kind)
    requestCounter = requestCounter + 1
    return ('%s:%s:%s:%s'):format(
        kind or 'request',
        GetPlayerServerId(PlayerId()),
        GetGameTimer(),
        requestCounter
    )
end

local function normalizedHash(value)
    local numberValue = tonumber(value)
    if not numberValue then
        return nil
    end

    numberValue = numberValue % 4294967296
    if numberValue < 0 then
        numberValue = numberValue + 4294967296
    end
    return numberValue
end

local function sameHash(left, right)
    local leftHash = normalizedHash(left)
    local rightHash = normalizedHash(right)
    return leftHash ~= nil and rightHash ~= nil and leftHash == rightHash
end

local function getDriverVehicle()
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) or not IsPedInAnyVehicle(ped, false) then
        return nil, 'You must be driving an add-on vehicle to use the handling editor.', 'not_in_vehicle'
    end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil, 'The current vehicle is no longer available.', 'vehicle_missing'
    end

    if GetPedInVehicleSeat(vehicle, -1) ~= ped then
        return nil, 'Only the driver can open the handling editor.', 'not_driver'
    end

    return vehicle
end

local function getVehicleIdentity(vehicle)
    local modelHash = GetEntityModel(vehicle)
    local displayCode = GetDisplayNameFromVehicleModel(modelHash)
    local displayName = displayCode

    if type(displayCode) == 'string' and displayCode ~= '' then
        local localized = GetLabelText(displayCode)
        if localized and localized ~= '' and localized ~= 'NULL' then
            displayName = localized
        end
    end

    local modelName = displayCode
    if type(GetEntityArchetypeName) == 'function' then
        local ok, archetype = pcall(GetEntityArchetypeName, vehicle)
        if ok and type(archetype) == 'string' and archetype ~= '' then
            modelName = archetype
        end
    end

    if type(modelName) ~= 'string' or modelName == '' or modelName == 'CARNOTFOUND' then
        modelName = ('0x%08X'):format(normalizedHash(modelHash) or 0)
    end

    if type(displayName) ~= 'string' or displayName == '' or displayName == 'CARNOTFOUND' then
        displayName = modelName
    end

    local plate = GetVehicleNumberPlateText(vehicle) or ''
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')

    return {
        modelHash = modelHash,
        modelName = modelName,
        displayName = displayName,
        plate = plate,
    }
end

local function fieldNativeClass(field)
    return field.class or field.className or field.handlingClass or field.nativeClass or 'CHandlingData'
end

local function fieldNativeName(field)
    return field.name or field.field or field.fieldName or field.nativeName
end

local function fieldType(field)
    local valueType = tostring(field.type or ''):lower()
    if valueType == 'float' or valueType == 'number' then
        return 'number'
    elseif valueType == 'int' or valueType == 'integer' then
        return 'integer'
    elseif valueType == 'vector3' or valueType == 'vector' then
        return 'vector'
    elseif valueType == 'string' or valueType == 'text' or valueType == 'flags' then
        return 'text'
    end

    if type(field.value) == 'table' and field.value.x ~= nil then
        return 'vector'
    elseif type(field.value) == 'number' then
        return 'number'
    end
    return 'text'
end

local function normalizeFieldValue(field, value)
    local valueType = fieldType(field)

    if valueType == 'number' then
        local numberValue = parseFiniteNumber(value)
        if numberValue == nil then
            return nil, 'Enter a finite number.'
        end
        return numberValue
    elseif valueType == 'integer' then
        local numberValue = parseFiniteNumber(value)
        if numberValue == nil or numberValue % 1 ~= 0 then
            return nil, 'Enter a whole number.'
        end
        return numberValue
    elseif valueType == 'vector' then
        if type(value) ~= 'table' then
            return nil, 'Enter all three vector components.'
        end

        local x = parseFiniteNumber(value.x)
        local y = parseFiniteNumber(value.y)
        local z = parseFiniteNumber(value.z)
        if x == nil or y == nil or z == nil then
            return nil, 'Every vector component must be a finite number.'
        end
        return { x = x, y = y, z = z }
    end

    if type(value) ~= 'string' then
        return nil, 'Enter a text value.'
    end
    return value
end

local function canPreviewField(field)
    local nativeName = fieldNativeName(field)
    local nativeClass = fieldNativeClass(field)
    local valueType = fieldType(field)
    return field.live == true
        and type(nativeName) == 'string'
        and nativeName ~= ''
        and (valueType == 'number' or valueType == 'integer' or valueType == 'vector')
end

local function getLiveValue(vehicle, field)
    if vehicle == 0 or not DoesEntityExist(vehicle) or not canPreviewField(field) then
        return false, nil
    end

    local nativeClass = fieldNativeClass(field)
    local nativeName = fieldNativeName(field)
    local valueType = fieldType(field)
    local result

    local ok = pcall(function()
        if valueType == 'number' then
            result = GetVehicleHandlingFloat(vehicle, nativeClass, nativeName)
        elseif valueType == 'integer' then
            result = GetVehicleHandlingInt(vehicle, nativeClass, nativeName)
        else
            local vector = GetVehicleHandlingVector(vehicle, nativeClass, nativeName)
            result = { x = vector.x + 0.0, y = vector.y + 0.0, z = vector.z + 0.0 }
        end
    end)

    if not ok then
        return false, nil
    end

    if valueType == 'vector' then
        if not finiteNumber(result.x) or not finiteNumber(result.y) or not finiteNumber(result.z) then
            return false, nil
        end
    elseif not finiteNumber(result) then
        return false, nil
    end

    return true, result
end

local function closeEnough(actual, expected)
    if not finiteNumber(actual) or not finiteNumber(expected) then
        return false
    end

    local scale = math.max(1.0, math.abs(actual), math.abs(expected))
    return math.abs(actual - expected)
        <= LIVE_FLOAT_ABSOLUTE_TOLERANCE + LIVE_FLOAT_RELATIVE_TOLERANCE * scale
end

local function liveValueMatches(field, actual, expected)
    local valueType = fieldType(field)
    if valueType == 'integer' then
        return finiteNumber(actual) and finiteNumber(expected) and actual == expected
    elseif valueType == 'number' then
        return closeEnough(actual, expected)
    elseif valueType == 'vector' then
        return type(actual) == 'table'
            and type(expected) == 'table'
            and closeEnough(actual.x, expected.x)
            and closeEnough(actual.y, expected.y)
            and closeEnough(actual.z, expected.z)
    end
    return false
end

local function setLiveValue(vehicle, field, value)
    if vehicle == 0 or not DoesEntityExist(vehicle) or not canPreviewField(field) then
        return false
    end

    local nativeClass = fieldNativeClass(field)
    local nativeName = fieldNativeName(field)
    local valueType = fieldType(field)

    local nativeResult
    local ok = pcall(function()
        if valueType == 'number' then
            nativeResult = SetVehicleHandlingFloat(vehicle, nativeClass, nativeName, value + 0.0)
        elseif valueType == 'integer' then
            nativeResult = SetVehicleHandlingInt(vehicle, nativeClass, nativeName, value)
        else
            nativeResult = SetVehicleHandlingVector(
                vehicle,
                nativeClass,
                nativeName,
                vector3(value.x + 0.0, value.y + 0.0, value.z + 0.0)
            )
        end
    end)

    -- Handling setters usually return nil (void), but propagate an explicit
    -- false if a runtime/native wrapper rejects the field. A successful call is
    -- not enough: the game may clamp or ignore unsupported values, so read the
    -- field back and verify what actually became active.
    if not ok or nativeResult == false then
        return false
    end

    local readOk, activeValue = getLiveValue(vehicle, field)
    return readOk and liveValueMatches(field, activeValue, value)
end

local function pendingKey(sessionId, fieldId)
    return ('%s\0%s'):format(tostring(sessionId), tostring(fieldId))
end

local function revertPendingSession(sessionId)
    if not sessionId then
        return
    end

    for requestId, pending in pairs(pendingSaves) do
        if pending.sessionId == sessionId then
            if pending.liveApplied and pending.previousLiveValue ~= nil then
                setLiveValue(pending.vehicle, pending.field, pending.previousLiveValue)
            end

            pendingSaves[requestId] = nil
            local key = pendingKey(pending.sessionId, pending.fieldId)
            if pendingByField[key] == requestId then
                pendingByField[key] = nil
            end
        end
    end
end

local function closeEditor(reason, tellServer)
    if not editor.open then
        return
    end

    local closingSession = editor.sessionId
    revertPendingSession(closingSession)
    editor.open = false
    editor.sessionId = nil
    editor.canEdit = false
    editor.vehicle = 0
    editor.modelHash = nil
    editor.fields = {}

    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'close', reason = reason or 'closed' })

    if tellServer ~= false and closingSession then
        TriggerServerEvent(EVENT_PREFIX .. ':server:closeSession', { sessionId = closingSession })
    end
end

local function indexFields(groups)
    local indexed = {}
    if type(groups) ~= 'table' then
        return indexed
    end

    for _, group in ipairs(groups) do
        if type(group) == 'table' and type(group.fields) == 'table' then
            for _, field in ipairs(group.fields) do
                if type(field) == 'table' and field.id ~= nil then
                    local id = tostring(field.id)
                    field.id = id
                    field.savedValue = copyValue(field.value)
                    field.originalValue = copyValue(field.value)
                    indexed[id] = field
                end
            end
        end
    end
    return indexed
end

RegisterNetEvent(EVENT_PREFIX .. ':client:requestVehicle', function(payload)
    local requestId = type(payload) == 'table' and payload.requestId or payload
    if requestId == nil then
        return
    end

    local vehicle, _, errorCode = getDriverVehicle()
    if not vehicle then
        TriggerServerEvent(EVENT_PREFIX .. ':server:inspectVehicle', {
            requestId = requestId,
            error = errorCode,
        })
        return
    end

    local identity = getVehicleIdentity(vehicle)
    identity.requestId = requestId
    TriggerServerEvent(EVENT_PREFIX .. ':server:inspectVehicle', identity)
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:captureVanilla', function(payload)
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' or type(payload.schema) ~= 'table' then return end
    local vehicle = getDriverVehicle()
    if not vehicle or not sameHash(GetEntityModel(vehicle), payload.modelHash) then
        TriggerServerEvent(EVENT_PREFIX .. ':server:vanillaCapture', { token = payload.token, fields = {} })
        return
    end

    local captured = {}
    for className, kinds in pairs(payload.schema) do
        if type(className) == 'string' and type(kinds) == 'table' then
            for kind, names in pairs(kinds) do
                local valueType = kind == 'ints' and 'integer' or (kind == 'vectors' and 'vector' or 'number')
                if type(names) == 'table' then
                    for _, name in ipairs(names) do
                        local field = { class = className, name = name, type = valueType, live = true }
                        local readOk, value = getLiveValue(vehicle, field)
                        -- A getter returning a default is not proof that a field exists.
                        -- Require a harmless same-value setter and matching readback.
                        if readOk and setLiveValue(vehicle, field, value) then
                            captured[className .. '.' .. name] = copyValue(value)
                        end
                    end
                end
            end
        end
    end
    TriggerServerEvent(EVENT_PREFIX .. ':server:vanillaCapture', { token = payload.token, fields = captured })
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:vanillaSync', function(payload)
    if type(payload) ~= 'table' or type(payload.models) ~= 'table' or type(payload.fields) ~= 'table' then return end
    vanillaOverrides = payload.models
    vanillaFields = payload.fields
    vanillaApplied = {}
end)

local function applyVanillaToVehicle(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return end
    local model = vanillaOverrides[tostring(normalizedHash(GetEntityModel(vehicle)))]
    if type(model) ~= 'table' or type(model.overrides) ~= 'table' then return end
    local revision = tonumber(model.revision) or 0
    if vanillaApplied[vehicle] == revision then return end
    local succeeded = true
    for id, value in pairs(model.overrides) do
        local field = vanillaFields[id]
        if type(field) ~= 'table' or not setLiveValue(vehicle, field, value) then succeeded = false end
    end
    if succeeded then vanillaApplied[vehicle] = revision end
end

RegisterNetEvent(EVENT_PREFIX .. ':client:open', function(payload)
    if type(payload) ~= 'table' or payload.sessionId == nil then
        notify('The server returned an invalid editor session.', 'error')
        return
    end

    local vehicle, errorMessage = getDriverVehicle()
    if not vehicle then
        notify(errorMessage, 'error')
        TriggerServerEvent(EVENT_PREFIX .. ':server:closeSession', { sessionId = payload.sessionId })
        return
    end

    local actualModel = GetEntityModel(vehicle)
    local expectedModel = type(payload.vehicle) == 'table' and payload.vehicle.modelHash or nil
    if expectedModel ~= nil and not sameHash(actualModel, expectedModel) then
        notify('You changed vehicles before the editor finished opening.', 'error')
        TriggerServerEvent(EVENT_PREFIX .. ':server:closeSession', { sessionId = payload.sessionId })
        return
    end

    if editor.open then
        closeEditor('replaced', true)
    end

    payload.groups = type(payload.groups) == 'table' and payload.groups or {}
    payload.canEdit = payload.canEdit == true

    editor.open = true
    editor.sessionId = tostring(payload.sessionId)
    editor.canEdit = payload.canEdit
    editor.vehicle = vehicle
    editor.modelHash = actualModel
    editor.fields = indexFields(payload.groups)

    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({
        action = 'open',
        data = payload,
        resourceName = RESOURCE_NAME,
    })
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:saveResult', function(payload)
    if type(payload) ~= 'table' or payload.requestId == nil then
        return
    end

    local requestId = tostring(payload.requestId)
    local pending = pendingSaves[requestId]
    if not pending then
        return
    end

    pendingSaves[requestId] = nil
    local key = pendingKey(pending.sessionId, pending.fieldId)
    if pendingByField[key] == requestId then
        pendingByField[key] = nil
    end

    local ok = payload.ok == true
    local returnedValue = payload.value

    if ok then
        local savedValue = returnedValue ~= nil and returnedValue or pending.submittedValue
        pending.field.savedValue = copyValue(savedValue)

        -- Always replace the optimistic value with the server-canonical value.
        -- This matters if persistence normalizes or rounds the submitted input.
        if pending.liveAttempted and pending.previousLiveValue ~= nil then
            local canonicalApplied = setLiveValue(pending.vehicle, pending.field, savedValue)
            if not canonicalApplied and pending.previousLiveValue ~= nil then
                -- Do not knowingly leave an unpersisted optimistic value active.
                setLiveValue(pending.vehicle, pending.field, pending.previousLiveValue)
            end
            pending.liveApplied = canonicalApplied
        end
    else
        if pending.liveApplied and pending.previousLiveValue ~= nil then
            setLiveValue(pending.vehicle, pending.field, pending.previousLiveValue)
        end

        if payload.conflict == true and returnedValue ~= nil then
            pending.field.savedValue = copyValue(returnedValue)
        end
    end

    local liveWarning = ok and pending.liveAttempted and not pending.liveApplied
    local effectiveRestartRequired = resolveRestartRequired(payload.restartRequired, liveWarning)
    if effectiveRestartRequired ~= nil then
        pending.field.restartRequired = effectiveRestartRequired
    end

    if editor.open and editor.sessionId == pending.sessionId then
        SendNUIMessage({
            action = 'saveResult',
            requestId = requestId,
            fieldId = pending.fieldId,
            ok = ok,
            value = returnedValue,
            error = payload.error,
            conflict = payload.conflict == true,
            restartRequired = effectiveRestartRequired,
            previousValue = pending.expectedValue,
            submittedValue = pending.submittedValue,
            liveWarning = liveWarning,
        })
    elseif not ok then
        notify(payload.error or 'The handling change could not be saved.', 'error')
    end
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:restartResult', function(payload)
    payload = type(payload) == 'table' and payload or {}
    local responseId = payload.requestId ~= nil and tostring(payload.requestId) or nil
    if not pendingRestartId or not responseId or responseId ~= pendingRestartId then
        return
    end
    pendingRestartId = nil

    if payload.ok == true then
        notify(payload.message or 'Vehicle resource restarted. The handling index is refreshing.', 'success')
    else
        notify(payload.error or payload.message or 'The vehicle resource could not be restarted.', 'error')
    end
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:captureRestartVehicles', function(payload)
    if type(payload) ~= 'table'
        or type(payload.transactionId) ~= 'string'
        or type(payload.vehicles) ~= 'table'
    then
        return
    end

    local properties = {}
    for _, networkId in ipairs(payload.vehicles) do
        networkId = tonumber(networkId)
        if networkId and NetworkDoesEntityExistWithNetworkId(networkId) then
            local vehicle = NetToVeh(networkId)
            if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
                local ok, snapshot = pcall(lib.getVehicleProperties, vehicle)
                if ok and type(snapshot) == 'table' then
                    properties[tostring(networkId)] = snapshot
                end
            end
        end
    end

    TriggerServerEvent(EVENT_PREFIX .. ':server:restartVehicleProperties', {
        transactionId = payload.transactionId,
        vehicles = properties,
    })
end)

local function releaseRestartModels(transactionId)
    local models = restartLoadedModels[transactionId]
    if not models then return end

    for _, model in ipairs(models) do
        SetModelAsNoLongerNeeded(model)
    end
    restartLoadedModels[transactionId] = nil
end

RegisterNetEvent(EVENT_PREFIX .. ':client:prepareRestartModels', function(payload)
    if type(payload) ~= 'table'
        or type(payload.transactionId) ~= 'string'
        or type(payload.models) ~= 'table'
    then
        return
    end

    local transactionId = payload.transactionId
    CreateThread(function()
        releaseRestartModels(transactionId)

        local models, seen = {}, {}
        local errorMessage
        if #payload.models > 512 then
            errorMessage = 'The restart requested too many vehicle models at once.'
        else
            for _, rawModel in ipairs(payload.models) do
                local model = normalizedHash(rawModel)
                local key = model and tostring(model) or nil
                if not model or not IsModelInCdimage(model) or not IsModelAVehicle(model) then
                    errorMessage = ('Vehicle model %s is not available after the resource restart.')
                        :format(tostring(rawModel))
                    break
                end
                if not seen[key] then
                    seen[key] = true
                    models[#models + 1] = model
                    RequestModel(model)
                    if type(RequestCollisionForModel) == 'function' then
                        RequestCollisionForModel(model)
                    end
                end
            end
        end

        if not errorMessage then
            -- Request every model first so streaming runs concurrently. Model
            -- readiness is reliable; add-on collision readiness is best effort
            -- because some packs never report it through the native.
            local deadline = GetGameTimer() + RESTART_MODEL_LOAD_TIMEOUT_MS
            while GetGameTimer() < deadline do
                local ready = true
                for _, model in ipairs(models) do
                    if not HasModelLoaded(model) then
                        ready = false
                        RequestModel(model)
                    end
                    if type(RequestCollisionForModel) == 'function' then
                        RequestCollisionForModel(model)
                    end
                end
                if ready then break end
                Wait(50)
            end

            local missing = 0
            for _, model in ipairs(models) do
                if not HasModelLoaded(model) then missing = missing + 1 end
            end
            if missing > 0 then
                errorMessage = ('%d vehicle model(s) did not stream before the safety timeout.')
                    :format(missing)
            elseif type(HasCollisionForModelLoaded) == 'function' then
                local collisionDeadline = GetGameTimer() + RESTART_COLLISION_GRACE_MS
                while GetGameTimer() < collisionDeadline do
                    local collisionReady = true
                    for _, model in ipairs(models) do
                        if not HasCollisionForModelLoaded(model) then
                            collisionReady = false
                            if type(RequestCollisionForModel) == 'function' then
                                RequestCollisionForModel(model)
                            end
                        end
                    end
                    if collisionReady then break end
                    Wait(50)
                end
            end
        end

        -- Retain the streaming references until the server finishes spawning,
        -- even on failure; the overlay/result event releases them centrally.
        restartLoadedModels[transactionId] = models
        TriggerServerEvent(EVENT_PREFIX .. ':server:restartModelsReady', {
            transactionId = transactionId,
            ok = errorMessage == nil,
            error = errorMessage,
        })
    end)
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:applyRestartVehicle', function(payload)
    if type(payload) ~= 'table'
        or type(payload.transactionId) ~= 'string'
        or type(payload.applyId) ~= 'string'
        or type(payload.properties) ~= 'table'
    then
        return
    end

    CreateThread(function()
        local networkId = tonumber(payload.networkId)
        local expectedModel = normalizedHash(payload.model)
        local vehicle = 0
        local errorMessage

        if not networkId or not expectedModel then
            errorMessage = 'The restored vehicle identity was invalid.'
        else
            local entityDeadline = GetGameTimer() + RESTART_ENTITY_APPEAR_TIMEOUT_MS
            while not NetworkDoesEntityExistWithNetworkId(networkId)
                and GetGameTimer() < entityDeadline
            do
                Wait(25)
            end

            if NetworkDoesEntityExistWithNetworkId(networkId) then
                vehicle = NetToVeh(networkId)
            end
            if vehicle == 0 or not DoesEntityExist(vehicle) then
                errorMessage = 'The restored vehicle did not stream to its owning client.'
            elseif not sameHash(GetEntityModel(vehicle), expectedModel) then
                errorMessage = 'The restored network entity has the wrong vehicle model.'
            end
        end

        if not errorMessage then
            local controlDeadline = GetGameTimer() + RESTART_CONTROL_TIMEOUT_MS
            while not NetworkHasControlOfEntity(vehicle) and GetGameTimer() < controlDeadline do
                NetworkRequestControlOfEntity(vehicle)
                Wait(25)
            end
            if not NetworkHasControlOfEntity(vehicle) then
                errorMessage = 'Vehicle ownership migrated before its properties could be applied.'
            end
        end

        if not errorMessage then
            FreezeEntityPosition(vehicle, true)
            SetEntityCollision(vehicle, false, false)
            local applyOk, applied = pcall(lib.setVehicleProperties, vehicle, payload.properties)
            if not applyOk then
                errorMessage = tostring(applied)
            elseif applied ~= true then
                errorMessage = 'Vehicle ownership changed while applying its exact properties.'
            end
        end

        TriggerServerEvent(EVENT_PREFIX .. ':server:restartVehicleApplied', {
            transactionId = payload.transactionId,
            applyId = payload.applyId,
            ok = errorMessage == nil,
            error = errorMessage,
        })
    end)
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:finishRestartVehicle', function(payload)
    if type(payload) ~= 'table' or type(payload.transactionId) ~= 'string' then return end
    if activeRestartOverlayId ~= payload.transactionId
        and not restartLoadedModels[payload.transactionId]
    then
        return
    end

    local networkId = tonumber(payload.networkId)
    if not networkId or not NetworkDoesEntityExistWithNetworkId(networkId) then return end
    local vehicle = NetToVeh(networkId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return end

    SetEntityVelocity(vehicle, 0.0, 0.0, 0.0)
    SetEntityCollision(vehicle, true, true)
    FreezeEntityPosition(vehicle, false)
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:restartOverlay', function(payload)
    payload = type(payload) == 'table' and payload or {}
    local transactionId = payload.transactionId ~= nil and tostring(payload.transactionId) or nil

    if payload.visible == true and transactionId then
        activeRestartOverlayId = transactionId
        local ped = PlayerPedId()
        if ped and ped ~= 0 and not restartFreezeApplied then
            local alreadyFrozen = type(IsEntityPositionFrozen) == 'function'
                and IsEntityPositionFrozen(ped)
                or false
            if not alreadyFrozen then
                FreezeEntityPosition(ped, true)
                restartFreezeApplied = true
            end
        end
    elseif transactionId
        and activeRestartOverlayId ~= transactionId
        and not restartLoadedModels[transactionId]
    then
        return
    else
        if transactionId then releaseRestartModels(transactionId) end
        activeRestartOverlayId = nil
        if restartFreezeApplied then
            local ped = PlayerPedId()
            if ped and ped ~= 0 then FreezeEntityPosition(ped, false) end
            restartFreezeApplied = false
        end
    end

    SendNUIMessage({
        action = 'restartOverlay',
        visible = payload.visible == true,
        resource = payload.resource,
        stage = payload.stage,
        detail = payload.detail,
    })
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:notify', function(payload, notificationType)
    if type(payload) == 'table' then
        notify(payload.message or payload.error, payload.type or notificationType)
    else
        notify(payload, notificationType)
    end
end)

RegisterNetEvent(EVENT_PREFIX .. ':client:close', function(payload)
    local reason = type(payload) == 'table' and payload.reason or payload
    closeEditor(reason or 'server_closed', false)
end)

RegisterNUICallback('saveField', function(data, callback)
    if not editor.open or not editor.sessionId then
        callback({ ok = false, error = 'The editor session is closed.' })
        return
    end

    if not editor.canEdit then
        callback({ ok = false, error = 'This session is view-only.' })
        return
    end

    local vehicle, vehicleError = getDriverVehicle()
    if not vehicle or vehicle ~= editor.vehicle or not sameHash(GetEntityModel(vehicle), editor.modelHash) then
        callback({ ok = false, error = vehicleError or 'You are no longer driving the edited vehicle.' })
        closeEditor('vehicle_lost', true)
        notify(vehicleError or 'The editor closed because you are no longer driving that vehicle.', 'warning')
        return
    end

    local fieldId = data and data.fieldId ~= nil and tostring(data.fieldId) or nil
    local field = fieldId and editor.fields[fieldId] or nil
    if not field then
        callback({ ok = false, error = 'That field is not part of this session.' })
        return
    end

    local key = pendingKey(editor.sessionId, fieldId)
    if pendingByField[key] then
        callback({ ok = false, error = 'Wait for the current save to finish.' })
        return
    end

    local normalizedValue, validationError = normalizeFieldValue(field, data.value)
    if normalizedValue == nil then
        callback({ ok = false, error = validationError })
        return
    end

    local requestId = nextRequestId('save')
    local previousLiveValue = nil
    local liveApplied = false
    local liveAttempted = canPreviewField(field)

    if liveAttempted then
        local readOk, liveValue = getLiveValue(vehicle, field)
        if readOk then
            previousLiveValue = copyValue(liveValue)
            liveApplied = setLiveValue(vehicle, field, normalizedValue)
            if not liveApplied then
                -- A setter can partially apply or clamp a value. Restore the
                -- verified pre-edit value before waiting for persistence.
                setLiveValue(vehicle, field, previousLiveValue)
            end
        end
    end

    local pending = {
        requestId = requestId,
        sessionId = editor.sessionId,
        fieldId = fieldId,
        field = field,
        vehicle = vehicle,
        expectedValue = copyValue(field.savedValue),
        submittedValue = copyValue(normalizedValue),
        previousLiveValue = previousLiveValue,
        liveAttempted = liveAttempted,
        liveApplied = liveApplied,
    }

    pendingSaves[requestId] = pending
    pendingByField[key] = requestId

    callback({ ok = true, requestId = requestId, liveApplied = liveApplied })
    TriggerServerEvent(EVENT_PREFIX .. ':server:saveField', {
        requestId = requestId,
        sessionId = editor.sessionId,
        fieldId = fieldId,
        value = normalizedValue,
        expectedValue = pending.expectedValue,
    })
end)

RegisterNUICallback('close', function(_, callback)
    callback({ ok = true })
    closeEditor('user_closed', true)
end)

RegisterNUICallback('restartResource', function(_, callback)
    if not editor.open or not editor.sessionId then
        callback({ ok = false, error = 'The editor session is closed.' })
        return
    end

    if not editor.canEdit then
        callback({ ok = false, error = 'This session is view-only.' })
        return
    end

    if pendingRestartId then
        callback({ ok = false, error = 'A resource restart is already pending.' })
        return
    end

    for _, pending in pairs(pendingSaves) do
        if pending.sessionId == editor.sessionId then
            callback({ ok = false, error = 'Wait for field saves to finish before restarting.' })
            return
        end
    end

    local requestId = nextRequestId('restart')
    local sessionId = editor.sessionId
    pendingRestartId = requestId

    SetTimeout(RESTART_REQUEST_TIMEOUT_MS, function()
        if pendingRestartId == requestId then
            pendingRestartId = nil
            notify('The resource restart response timed out. Reopen the editor to retry.', 'warning')
        end
    end)

    callback({ ok = true, requestId = requestId })
    closeEditor('resource_restart', false)
    TriggerServerEvent(EVENT_PREFIX .. ':server:restartResource', {
        requestId = requestId,
        sessionId = sessionId,
    })
end)

local function closeForVehicleLoss()
    if not editor.open then return end
    closeEditor('vehicle_lost', true)
    notify('The editor closed because you are no longer driving that vehicle.', 'warning')
end

-- ox_lib cache events handle the common exit/switch/seat-change cases without
-- polling natives. The slow fallback below only catches deletion/model changes.
lib.onCache('vehicle', function(vehicle)
    if editor.open and vehicle ~= editor.vehicle then closeForVehicleLoss() end
end)

lib.onCache('seat', function(seat)
    if editor.open and seat ~= -1 then closeForVehicleLoss() end
end)

CreateThread(function()
    Wait(0)
    TriggerServerEvent(EVENT_PREFIX .. ':server:requestVanillaSync')
    while true do
        for _, vehicle in ipairs(GetGamePool('CVehicle')) do applyVanillaToVehicle(vehicle) end
        Wait(500)
    end
end)

CreateThread(function()
    while true do
        if editor.open then
            Wait(1500)
            local vehicle = getDriverVehicle()
            if not vehicle
                or vehicle ~= editor.vehicle
                or not DoesEntityExist(editor.vehicle)
                or not sameHash(GetEntityModel(editor.vehicle), editor.modelHash)
            then
                closeForVehicleLoss()
            end
        else
            Wait(1000)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= RESOURCE_NAME then
        return
    end

    if editor.open then
        revertPendingSession(editor.sessionId)
        SetNuiFocus(false, false)
        SetNuiFocusKeepInput(false)
    end
    if restartFreezeApplied then
        local ped = PlayerPedId()
        if ped and ped ~= 0 then FreezeEntityPosition(ped, false) end
        restartFreezeApplied = false
    end
    for transactionId in pairs(restartLoadedModels) do
        releaseRestartModels(transactionId)
    end
end)
