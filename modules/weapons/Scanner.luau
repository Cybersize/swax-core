-- Read-only equipped-Tool config discovery. No require(), decompile, script
-- execution, projectile/tracer guessing or unrestricted workspace searches.
return function(ctx, ConfigService, Maid)
    local Scanner = {MAX_NODES=512, MAX_DEPTH=24, MAX_SPEED=1000000}
    local SPEED_KEYS = {bulletspeed=true, projectilespeed=true, muzzlevelocity=true, bulletvelocity=true}
    local watchMaid = Maid.new()
    local dirty = true
    local state = {tool=nil, speed=nil, reason="no_equipped_tool", source="", field="", examined=0, matches=0}

    local function normalize(key) return key:lower():gsub("[_%s%-]", "") end
    local function unitKey(key)
        local name = normalize(key)
        return name == "units" or name == "speedunits" or name == "projectilespeedunits"
            or name == "bulletspeedunits" or name == "muzzlevelocityunits" or name == "bulletvelocityunits"
    end
    local function invalidate() dirty = true end
    local function reset(tool, reason)
        watchMaid:Clean()
        state = {tool=tool, speed=nil, reason=reason, source="", field="", examined=0, matches=0}
        dirty = true
    end
    local function equippedTool()
        local char = ctx.localPlayer.Character
        if not char or not char:IsDescendantOf(ctx.services.Workspace) then return nil, "no_equipped_tool" end
        local tool, count = nil, 0
        for index, child in ipairs(char:GetChildren()) do
            if index > Scanner.MAX_NODES then return nil, "equipment_scan_limit" end
            if child:IsA("Tool") then
                count += 1
                if count > 1 then return nil, "multiple_equipped_tools" end
                tool = child
            end
        end
        return tool, tool and "not_scanned" or "no_equipped_tool"
    end
    local function refreshEquipment()
        local tool, reason = equippedTool()
        if tool ~= state.tool or (not tool and reason ~= state.reason) then reset(tool, reason) end
        return tool
    end
    local function path(object, suffix) return object:GetFullName() .. suffix end

    function Scanner.Scan()
        if not ctx.alive then return nil, "unloaded" end
        local tool = refreshEquipment()
        if not tool then dirty = false; return nil, state.reason end
        watchMaid:Clean()
        state.speed, state.source, state.field, state.matches, state.examined = nil, "", "", 0, 0
        dirty = false
        watchMaid:Give(tool.DescendantAdded:Connect(invalidate))
        watchMaid:Give(tool.DescendantRemoving:Connect(invalidate))
        local nodes, records, candidates = {{object=tool, depth=0}}, {}, {}
        local limit, unreadable = false, false
        local index = 1
        while index <= #nodes do
            local item = nodes[index]
            local object = item.object
            local ok, attrs = pcall(function() return object:GetAttributes() end)
            if not ok or type(attrs) ~= "table" then attrs = {}; unreadable = true end
            local children = object:GetChildren()
            records[object] = {attributes=attrs, children=children}
            state.examined += 1
            watchMaid:Give(object.AttributeChanged:Connect(function(key)
                if SPEED_KEYS[normalize(key)] or unitKey(key) then invalidate() end
            end))
            local attributeCount = 0
            for key, value in pairs(attrs) do
                attributeCount += 1
                if attributeCount > 64 then limit = true; break end
                if SPEED_KEYS[normalize(key)] then
                    candidates[#candidates + 1] = {object=object, key=key, value=value,
                        source=path(object, " [" .. key .. " attribute]")}
                end
            end
            if object:IsA("ValueBase") then
                watchMaid:Give(object:GetPropertyChangedSignal("Name"):Connect(invalidate))
                if SPEED_KEYS[normalize(object.Name)] or unitKey(object.Name) then
                    watchMaid:Give(object.Changed:Connect(invalidate))
                end
                if SPEED_KEYS[normalize(object.Name)] then
                    candidates[#candidates + 1] = {object=object, key=object.Name, value=object.Value,
                        source=path(object, ".Value")}
                end
            end
            for _, child in ipairs(children) do
                if #nodes >= Scanner.MAX_NODES or item.depth >= Scanner.MAX_DEPTH then limit = true; break end
                nodes[#nodes + 1] = {object=child, depth=item.depth + 1}
            end
            index += 1
        end
        if limit then state.reason = "scan_limit"; return nil, state.reason end
        if unreadable then state.reason = "unreadable_config"; return nil, state.reason end

        -- An explicit non-stud unit is not silently converted. Missing unit
        -- metadata assumes the recognized game's field uses studs/second.
        local function unitsSupported(candidate)
            local supported = true
            local function check(key, value)
                local name = normalize(key)
                if name ~= "units" and name ~= "speedunits" and name ~= normalize(candidate.key) .. "units" then return end
                if type(value) ~= "string" then supported = false; return end
                local unit = value:lower():gsub("[%s_]", "")
                if unit ~= "studs/s" and unit ~= "stud/s" and unit ~= "studs/sec" and unit ~= "stud/sec"
                    and unit ~= "studs/second" and unit ~= "stud/second" and unit ~= "studspersecond"
                    and unit ~= "studpersecond" then supported = false end
            end
            local object = candidate.object
            for _ = 1, Scanner.MAX_DEPTH + 2 do
                local record = records[object]
                if not record then return false end
                for key, value in pairs(record.attributes) do check(key, value) end
                for _, child in ipairs(record.children) do
                    if child:IsA("ValueBase") and unitKey(child.Name) then check(child.Name, child.Value) end
                end
                if object == tool then return supported end
                object = object.Parent
            end
            return false
        end
        local chosen, source, field = nil, nil, nil
        state.matches = #candidates
        for _, candidate in ipairs(candidates) do
            local speed = candidate.value
            if type(speed) ~= "number" or speed ~= speed or speed <= 0 or speed > Scanner.MAX_SPEED then
                state.reason = "invalid_speed_value"; return nil, state.reason
            end
            if not unitsSupported(candidate) then state.reason = "unsupported_or_conflicting_units"; return nil, state.reason end
            if chosen ~= nil and speed ~= chosen then state.reason = "conflicting_speed_values"; return nil, state.reason end
            chosen, source, field = speed, source or candidate.source, field or candidate.key
        end
        if not chosen then state.reason = "no_readable_speed_config"; return nil, state.reason end
        -- Never retain a scan if the weapon was unequipped/replaced.
        if tool ~= equippedTool() then reset(nil, "equipment_changed"); return nil, state.reason end
        state.speed, state.source, state.field, state.reason = chosen, source, field, "detected_config"
        return chosen, state.reason
    end

    function Scanner.GetEffectiveSpeed()
        if not ctx.alive then return 0, "off" end
        refreshEquipment()
        local manual = ConfigService.Get("BallisticSpeed")
        if manual <= 0 then return 0, "off" end
        if not ConfigService.Get("AutoProjectileSpeed") then return manual, "manual" end
        if dirty then Scanner.Scan() end
        if state.speed then return state.speed, "auto" end
        return manual, "manual_fallback"
    end
    function Scanner.GetStatus()
        local effective, mode = Scanner.GetEffectiveSpeed()
        local result = table.clone(state)
        result.effectiveSpeed, result.mode = effective, mode
        return result
    end
    function Scanner.Describe()
        local info = Scanner.GetStatus()
        if info.mode == "off" then return "Projectile Mode off" end
        if info.mode == "manual" then return string.format("Manual: %g studs/s", info.effectiveSpeed) end
        if info.mode == "auto" then return string.format("Auto: %g studs/s | %s", info.speed, info.source) end
        return string.format("Manual fallback: %g studs/s | %s", info.effectiveSpeed, info.reason)
    end
    function Scanner.Update()
        if not ctx.alive then return end
        refreshEquipment()
        if ConfigService.Get("AutoProjectileSpeed") and ConfigService.Get("BallisticSpeed") > 0 then Scanner.Scan() end
    end
    ctx.maid:Give(function() watchMaid:Clean(); state.tool, state.speed = nil, nil end)
    return Scanner
end
