-- rig/Cache: isolated factory; dependencies are explicit parameters.
return function()
    -- Char cache (geometry) — weak keys so GC can collect dead chars
    local _geomCache = setmetatable({}, { __mode = "k" })

    local function _destroyGeomCache(char)
        local cache = _geomCache[char]
        if not cache then return end
        for _, conn in ipairs(cache.conns) do
            if conn and conn.Connected then pcall(function() conn:Disconnect() end) end
        end
        _geomCache[char] = nil
    end

    local function _getGeomCache(char)
        if not char then return nil end
        local cache = _geomCache[char]
        if cache then return cache end
        cache = {
            directParts = {}, allParts = {}, markers = {}, joints = {}, regionSources = {},
            humanoids = {}, humanoid = nil, anyPart = nil,
            bboxTime = 0, bboxCf = nil, bboxSize = nil,
            structHeadTime = 0, structHead = nil,
            structTorsoTime = 0, structTorso = nil,
            skeletonEdges = nil, skeletonTime = 0,
            conns = {},
        }
        local function addDesc(inst)
            if not inst then return end
            cache.bboxTime, cache.bboxCf, cache.bboxSize = 0, nil, nil
            cache.structHeadTime, cache.structHead = 0, nil
            cache.structTorsoTime, cache.structTorso = 0, nil
            table.clear(cache.regionSources)
            cache.skeletonEdges = nil
            if inst:IsA("Humanoid") then
                cache.humanoids[inst] = true
                cache.humanoid = cache.humanoid or inst
            elseif inst:IsA("BasePart") then
                cache.allParts[inst]    = true
                if inst.Parent == char then cache.directParts[inst] = true end
                cache.anyPart = cache.anyPart or inst
            elseif inst:IsA("Attachment") then
                cache.markers[inst] = true -- includes Bone (an Attachment subclass)
            elseif inst:IsA("Motor6D") then
                cache.joints[inst] = true
            end
        end
        for _, inst in ipairs(char:GetDescendants()) do addDesc(inst) end
        cache.conns[1] = char.DescendantAdded:Connect(addDesc)
        cache.conns[2] = char.DescendantRemoving:Connect(function(inst)
            cache.bboxTime, cache.bboxCf, cache.bboxSize = 0, nil, nil
            cache.structHeadTime, cache.structHead = 0, nil
            cache.structTorsoTime, cache.structTorso = 0, nil
            table.clear(cache.regionSources)
            cache.skeletonEdges = nil
            if inst:IsA("Humanoid") then
                cache.humanoids[inst] = nil
                if inst == cache.humanoid then cache.humanoid = next(cache.humanoids) end
            end
            if inst:IsA("BasePart") then
                cache.allParts[inst]   = nil
                cache.directParts[inst]= nil
                if cache.anyPart == inst then cache.anyPart = next(cache.allParts) end
            elseif inst:IsA("Attachment") then
                cache.markers[inst] = nil
            elseif inst:IsA("Motor6D") then
                cache.joints[inst] = nil
            end
        end)
        cache.conns[3] = char.AncestryChanged:Connect(function()
            if not char:IsDescendantOf(game) then _destroyGeomCache(char) end
        end)
        _geomCache[char] = cache
        return cache
    end


    local RigCache={Get=_getGeomCache,Destroy=_destroyGeomCache}
    function RigCache.Clean()
        for char in pairs(_geomCache) do _destroyGeomCache(char) end
    end

    return RigCache
end
