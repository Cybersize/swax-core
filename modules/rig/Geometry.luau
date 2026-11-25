-- rig/Geometry: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, RigCache, CoreMath)
    local UserInputService=ctx.services.UserInputService
    local _getGeomCache=RigCache.Get

    local GeometryService = {}

    local PART_NAMES = {
        Head             = { "Head" },
        UpperTorso       = { "UpperTorso", "Torso" },
        Torso            = { "UpperTorso", "Torso" },
        HumanoidRootPart = { "HumanoidRootPart", "HRP", "Root", "RootPart" },
        LowerTorso       = { "LowerTorso" },
        Feet             = { "LeftFoot", "RightFoot", "LeftLowerLeg", "RightLowerLeg" },
    }

    local BBOX_OFFSETS = {
        Head             =  0.40,
        UpperTorso       =  0.15,
        Torso            =  0.15,
        HumanoidRootPart =  0.00,
        LowerTorso       = -0.15,
        Feet             = -0.48,
    }

    -- Returns true if `part` is a descendant of a Tool or Accoutrement inside `char`.
    -- Equipped weapons/guns are parented as Tool → char, so their parts are nested one
    -- level deeper. Excluding them prevents ESP boxes from stretching to include guns.
    local function _isWeaponPart(part, char)
        local p = part.Parent
        while p and p ~= char do
            if p:IsA("Tool") or p:IsA("Accoutrement") then return true end
            p = p.Parent
        end
        return false
    end

    -- Keep scalar extrema while scanning; construct bounds vectors only once.
    -- Both cache sets and the last-resort descendant array share this filter/math.
    local function _boundsFromParts(char, parts, isArray)
        local minX, minY, minZ = math.huge, math.huge, math.huge
        local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
        local found = false
        local iterate = isArray and ipairs or pairs
        for key, value in iterate(parts) do
            local part = isArray and value or key
            if part and part.Parent and part:IsA("BasePart") and not _isWeaponPart(part, char) then
                local pos = part.Position
                local hs = CoreMath.WorldHalfExtents(part.CFrame, part.Size)
                minX = math.min(minX, pos.X - hs.X)
                minY = math.min(minY, pos.Y - hs.Y)
                minZ = math.min(minZ, pos.Z - hs.Z)
                maxX = math.max(maxX, pos.X + hs.X)
                maxY = math.max(maxY, pos.Y + hs.Y)
                maxZ = math.max(maxZ, pos.Z + hs.Z)
                found = true
            end
        end
        if not found then return nil, nil end
        local mn = Vector3.new(minX, minY, minZ)
        local mx = Vector3.new(maxX, maxY, maxZ)
        return CFrame.new((mn + mx) * 0.5), mx - mn
    end

    -- Returns (centerCFrame, sizeVector3) or (nil, nil).
    -- Preserve direct-body preference and exclude tool/accessory descendants.
    function GeometryService.GetCharBBox(char)
        if not char or not char.Parent then return nil, nil end
        local cache = _getGeomCache(char)
        if not cache then return nil, nil end
        local now = os.clock()
        if cache.bboxCf and now - cache.bboxTime < 0.05 then
            return cache.bboxCf, cache.bboxSize
        end

        local cf, size
        if cache.humanoid then
            cf, size = _boundsFromParts(char, cache.directParts, false)
        end
        if not cf then
            cf, size = _boundsFromParts(char, cache.allParts, false)
        end
        if not cf then
            -- GetBoundingBox cannot exclude equipped tools, so keep a filtered
            -- live scan as the final fallback for unusual or uncached models.
            cf, size = _boundsFromParts(char, char:GetDescendants(), true)
        end
        if not cf then return nil, nil end
        cache.bboxCf, cache.bboxSize, cache.bboxTime = cf, size, now
        return cf, size
    end

    function GeometryService.GetCharCenter(char)
        local cf = GeometryService.GetCharBBox(char)
        return cf and cf.Position or nil
    end

    -- Resolve anatomy before using mesh-shape guesses. Skinned mesh Positions can
    -- remain in the bind pose while the visible head follows an animated Bone.
    local RIG_REGION_TTL = 1
    local BONE_NAMES = {
        Head = { "Bip01_Head", "Bip001_Head", "mixamorig:Head", "Head", "b_head", "ValveBiped.Bip01_Head1" },
        UpperTorso = { "Bip01_Spine2", "Bip01_Spine1", "mixamorig:Spine2", "UpperTorso", "Chest", "Spine2" },
        Torso = { "Bip01_Spine2", "Bip01_Spine1", "mixamorig:Spine2", "Torso", "Chest", "Spine1" },
        LowerTorso = { "Bip01_Pelvis", "mixamorig:Hips", "LowerTorso", "Pelvis", "Hips" },
        Feet = { "Bip01_L_Foot", "Bip01_R_Foot", "mixamorig:LeftFoot", "LeftFoot", "RightFoot" },
    }
    local ATTACHMENT_NAMES = {
        Head = { "HeadAimAttachment", "HeadCenter", "FaceCenterAttachment", "FaceFrontAttachment" },
        UpperTorso = { "BodyFrontAttachment", "BodyBackAttachment" },
        Torso = { "BodyFrontAttachment", "BodyBackAttachment" },
        LowerTorso = { "WaistCenterAttachment", "WaistFrontAttachment" },
    }

    local function _anatomyName(inst)
        return "_" .. inst.Name:lower():gsub("[^%w]+", "_") .. "_"
    end

    local function _isRigObject(inst, char)
        if not inst or not inst.Parent or not inst:IsDescendantOf(char) then return false end
        if _isWeaponPart(inst, char) then return false end
        local p = inst
        while p and p ~= char do
            local n = _anatomyName(p)
            if n:find("_gear", 1, true) or n:find("_weapon", 1, true)
                or n:find("_backpack", 1, true) or n:find("_helmet", 1, true)
                or n:find("_armor", 1, true) or n:find("_effect", 1, true)
                or n:find("_vfx_", 1, true) or n:match("^_hand_%d") then
                return false
            end
            p = p.Parent
        end
        return true
    end

    local function _isTargetBodyPart(part, char)
        if not _isRigObject(part, char) or not part:IsA("BasePart") then return false end
        -- Invisible animation carriers and root boxes are not anatomy. Exact named
        -- hitboxes are resolved separately and may legitimately be transparent.
        return part.Transparency < 0.98
    end

    local function _pickNamed(set, names, char, kind)
        if not names then return nil end
        local best, bestRank, bestPath = nil, math.huge, ""
        for inst in pairs(set) do
            if inst:IsA(kind) and _isRigObject(inst, char) then
                local lower = inst.Name:lower()
                for index, name in ipairs(names) do
                    if lower == name:lower() then
                        local rank = index * 2 + (inst.Parent == char and 0 or 1)
                        local path = inst:GetFullName()
                        if rank < bestRank or (rank == bestRank and path < bestPath) then
                            best, bestRank, bestPath = inst, rank, path
                        end
                        break
                    end
                end
            end
        end
        return best
    end

    -- Read this map's actual hitbox dimensions, rather than inventing a head-height
    -- offset. Only these two known, data-only config modules are required.
    local _rigProfile, _rigProfileRetry = nil, -math.huge
    local function _getRigProfile()
        if _rigProfile then return _rigProfile end
        local now = os.clock()
        if now - _rigProfileRetry < 2 then return nil end
        _rigProfileRetry = now
        local features = game:GetService("ReplicatedStorage"):FindFirstChild("Features")
        local combat = features and features:FindFirstChild("Combat")
        local movement = features and features:FindFirstChild("Movement")
        local combatModule = combat and combat:FindFirstChild("CombatSharedConfig")
        local movementModule = movement and movement:FindFirstChild("MovementSharedConfig")
        if not combatModule or not combatModule:IsA("ModuleScript")
            or not movementModule or not movementModule:IsA("ModuleScript") then return nil end
        local ok, profile = pcall(function()
            local c = require(combatModule)
            local m = require(movementModule)
            if type(c) ~= "table" or type(m) ~= "table" or type(c.Hitboxes) ~= "table"
                or type(c.HitboxJointBackOffset) ~= "number"
                or type(m.MetersToStuds) ~= "number" or m.MetersToStuds <= 0 then return nil end
            local specs = {}
            for _, spec in ipairs(c.Hitboxes) do
                if type(spec) == "table" and type(spec.Bone) == "string"
                    and typeof(spec.Size) == "Vector3" then
                    specs[spec.Bone:lower()] = spec
                end
            end
            return { specs = specs, back = c.HitboxJointBackOffset, scale = m.MetersToStuds }
        end)
        if ok then _rigProfile = profile end
        return _rigProfile
    end

    local function _profileSource(char, cache, region)
        local names = BONE_NAMES[region]
        if not names then return nil end
        local profile = _getRigProfile()
        if not profile then return nil end
        for _, name in ipairs(names) do
            local spec = profile.specs[name:lower()]
            local bone = spec and _pickNamed(cache.markers, { name }, char, "Bone")
            if bone then
                local length = 0
                for _, child in ipairs(bone:GetChildren()) do
                    if child:IsA("Bone") then length = child.Position.Magnitude; break end
                end
                -- Matches CombatRules.GetHitboxCFrame: offset along the bone's
                -- LOCAL X axis, not world Y (important for crouch, prone and lean).
                local offset = (spec.Size.X * 0.5 - profile.back) * profile.scale
                    + (tonumber(spec.BoneOffset) or 0) * length
                return { instance = bone, kind = "ConfiguredBone", offset = Vector3.new(offset, 0, 0) }
            end
        end
        return nil
    end

    local function _resolveRegionSource(char, cache, region)
        local source = _profileSource(char, cache, region)
        if source then return source end
        local part = _pickNamed(cache.allParts, PART_NAMES[region], char, "BasePart")
        if part then return { instance = part, kind = "Part" } end
        local bone = _pickNamed(cache.markers, BONE_NAMES[region], char, "Bone")
        if bone then return { instance = bone, kind = "Bone" } end
        local attachment = _pickNamed(cache.markers, ATTACHMENT_NAMES[region], char, "Attachment")
        if attachment then return { instance = attachment, kind = "Attachment" } end
        if region == "Head" then
            -- A named Neck joint is stronger evidence than a tiny, high accessory.
            local joint = _pickNamed(cache.joints, { "Neck", "HeadJoint", "Head" }, char, "Motor6D")
            local connected = joint and joint.Part1
            if connected and _isTargetBodyPart(connected, char) then
                return { instance = connected, kind = "JointPart" }
            end
        end
        -- Custom names such as Character_11_Head_01_01 / JokerP_head_01_01.
        -- Prefer the largest actual head mesh, not teeth or an arbitrary pairs() tie.
        local token = region == "Head" and "_head_"
            or ((region == "Torso" or region == "UpperTorso") and "_body_")
        local best, bestVolume, bestPath = nil, 0, ""
        if token then
            for candidate in pairs(cache.allParts) do
                if _isTargetBodyPart(candidate, char) and _anatomyName(candidate):find(token, 1, true) then
                    local s = candidate.Size
                    local volume, path = s.X * s.Y * s.Z, candidate:GetFullName()
                    if volume > bestVolume or (volume == bestVolume and path < bestPath) then
                        best, bestVolume, bestPath = candidate, volume, path
                    end
                end
            end
        end
        if best then return { instance = best, kind = "NamedMesh" } end
        return nil
    end

    local function _animatedMarkerCFrame(inst)
        -- Bone inherits Attachment; test Bone FIRST. WorldPosition/WorldCFrame on
        -- a Bone do not include its animation Transform.
        if inst:IsA("Bone") then return inst.TransformedWorldCFrame end
        if inst:IsA("Attachment") then
            local parent = inst.Parent
            if parent and parent:IsA("Attachment") then
                return _animatedMarkerCFrame(parent) * inst.CFrame
            end
            return inst.WorldCFrame
        end
        return inst.CFrame
    end

    local function _getResolvedRegionPos(char, region)
        local cache = _getGeomCache(char)
        if not cache then return nil end
        local now = os.clock()
        local entry = cache.regionSources[region]
        local source = entry and entry.source
        local valid = source and source.instance and _isRigObject(source.instance, char)
            and source.instance.Name == entry.name
        if not entry or now - entry.time >= RIG_REGION_TTL or (source and not valid) then
            source = _resolveRegionSource(char, cache, region)
            cache.regionSources[region] = {
                source = source, time = now, name = source and source.instance.Name,
            }
        end
        if not source then return nil end
        local ok, pos = pcall(function()
            local cf = _animatedMarkerCFrame(source.instance)
            return source.offset and cf:PointToWorldSpace(source.offset) or cf.Position
        end)
        if ok and pos and pos.X == pos.X and pos.Y == pos.Y and pos.Z == pos.Z
            and math.abs(pos.X) < math.huge and math.abs(pos.Y) < math.huge
            and math.abs(pos.Z) < math.huge then return pos end
        cache.regionSources[region] = nil
        return nil
    end



    -- Skeleton topology is structural; pose positions are read live on each update.
    -- Unknown rigs with no real connections produce no skeleton, not a guessed body.
    GeometryService.SKELETON_LIMIT = 64
    local STANDARD_SKELETON_LINKS = {
        {{"Head"},{"UpperTorso","Torso"}},
        {{"UpperTorso","Torso"},{"LowerTorso"}},
        {{"UpperTorso","Torso"},{"LeftUpperArm","Left Arm"}},
        {{"LeftUpperArm"},{"LeftLowerArm"}},{{"LeftLowerArm"},{"LeftHand"}},
        {{"UpperTorso","Torso"},{"RightUpperArm","Right Arm"}},
        {{"RightUpperArm"},{"RightLowerArm"}},{{"RightLowerArm"},{"RightHand"}},
        {{"LowerTorso","Torso"},{"LeftUpperLeg","Left Leg"}},
        {{"LeftUpperLeg"},{"LeftLowerLeg"}},{{"LeftLowerLeg"},{"LeftFoot"}},
        {{"LowerTorso","Torso"},{"RightUpperLeg","Right Leg"}},
        {{"RightUpperLeg"},{"RightLowerLeg"}},{{"RightLowerLeg"},{"RightFoot"}},
    }
    local function _skeletonPriority(name)
        name=name:lower()
        for _,token in ipairs({"pelvis","spine","neck","head","upperarm","forearm","hand","thigh","calf","foot","torso","leg"}) do
            if name:find(token,1,true) then return 0 end
        end
        return 1
    end
    local function _buildSkeletonEdges(char,cache)
        local edges={}
        for marker in pairs(cache.markers) do
            local parent=marker.Parent
            if marker:IsA("Bone") and parent and parent:IsA("Bone")
                and _isRigObject(marker,char) and _isRigObject(parent,char) then
                table.insert(edges,{a=parent,b=marker,priority=_skeletonPriority(marker.Name),key=marker:GetFullName()})
            end
        end
        if #edges==0 then
            for joint in pairs(cache.joints) do
                local a,b=joint.Part0,joint.Part1
                if _isRigObject(joint,char) and a and b and _isRigObject(a,char) and _isRigObject(b,char)
                    and a.Name~="HumanoidRootPart" and b.Name~="HumanoidRootPart" then
                    table.insert(edges,{joint=joint,priority=0,key=joint:GetFullName()})
                end
            end
        end
        if #edges==0 then
            for index,link in ipairs(STANDARD_SKELETON_LINKS) do
                local a=_pickNamed(cache.allParts,link[1],char,"BasePart")
                local b=_pickNamed(cache.allParts,link[2],char,"BasePart")
                if a and b and a~=b then table.insert(edges,{a=a,b=b,priority=0,key=tostring(index)}) end
            end
        end
        table.sort(edges,function(a,b)
            return a.priority<b.priority or (a.priority==b.priority and a.key<b.key)
        end)
        while #edges>GeometryService.SKELETON_LIMIT do table.remove(edges) end
        return edges
    end
    function GeometryService.GetSkeletonSegments(char)
        if not char or not char.Parent then return {} end
        local cache=_getGeomCache(char)
        local now=os.clock()
        if not cache.skeletonEdges or now-cache.skeletonTime>=1 then
            cache.skeletonEdges=_buildSkeletonEdges(char,cache)
            cache.skeletonTime=now
        end
        local segments={}
        for _,edge in ipairs(cache.skeletonEdges) do
            local a,b=edge.a,edge.b
            if edge.joint then a,b=edge.joint.Part0,edge.joint.Part1 end
            if a and b and _isRigObject(a,char) and _isRigObject(b,char) then
                local ok,pa,pb=pcall(function()
                    return _animatedMarkerCFrame(a).Position,_animatedMarkerCFrame(b).Position
                end)
                if ok and pa and pb and CoreMath.IsFinite(pa.X) and CoreMath.IsFinite(pa.Y) and CoreMath.IsFinite(pa.Z)
                    and CoreMath.IsFinite(pb.X) and CoreMath.IsFinite(pb.Y) and CoreMath.IsFinite(pb.Z)
                    and (pa-pb).Magnitude>1e-4 then table.insert(segments,{pa,pb}) end
            end
        end
        return segments
    end

    -- Structural part scorer (volume/shape/height heuristics)
    local STRUCT_TTL = 0.05   -- was 0.25 — stale positions on fast-moving rigs

    local function _vol(part) local s = part.Size; return s.X * s.Y * s.Z end
    local function _shapeRatio(part)
        -- No table allocation or sort — direct min/max is cheaper per part.
        local s  = part.Size
        local mn = math.min(s.X, s.Y, s.Z)
        local mx = math.max(s.X, s.Y, s.Z)
        return mx == 0 and 0 or mn / mx
    end

    local function _collectParts(model)
        if not model then return {} end
        local cache = _getGeomCache(model)
        local parts, seen = {}, {}
        if cache then
            for part in pairs(cache.directParts) do
                if _isTargetBodyPart(part, model) then seen[part]=true; table.insert(parts, part) end
            end
            if #parts < 2 then
                for part in pairs(cache.allParts) do
                    if not seen[part] and _isTargetBodyPart(part, model) then
                        seen[part]=true; table.insert(parts, part) end
                end
            end
        end
        if #parts < 2 then
            for _, p in ipairs(model:GetDescendants()) do
                if p:IsA("BasePart") and not seen[p] and _isTargetBodyPart(p, model) then
                    seen[p]=true; table.insert(parts,p)
                end
            end
        end
        return parts
    end

    local function _scoreParts(parts)
        if #parts == 0 then return {} end
        local minY, maxY, totalVol = math.huge, -math.huge, 0
        for _, p in ipairs(parts) do
            local hs = p.Size.Y * 0.5
            minY = math.min(minY, p.Position.Y - hs)
            maxY = math.max(maxY, p.Position.Y + hs)
            totalVol += _vol(p)
        end
        local bboxH  = math.max(maxY - minY, 0.01)
        local avgVol = totalVol / #parts
        local scored = {}
        for _, p in ipairs(parts) do
            local v    = _vol(p)
            local sr   = _shapeRatio(p)
            local relY = (p.Position.Y - minY) / bboxH
            local hs   = 0
            local vr   = v / avgVol
            if vr < 0.3 then hs+=3 elseif vr < 0.7 then hs+=2 elseif vr < 1.2 then hs+=1 elseif vr > 2.5 then hs-=2 end
            if sr > 0.75 then hs+=2 elseif sr > 0.50 then hs+=1 elseif sr < 0.25 then hs-=1 end
            if relY > 0.72 then hs+=4 elseif relY > 0.55 then hs+=2 elseif relY < 0.15 then hs-=3 end
            if v > avgVol * 4 then hs -= 5 end
            local ts = 0
            if vr > 0.8 and vr < 3.0 then ts+=3 elseif vr >= 3.0 then ts+=1 end
            if relY >= 0.30 and relY <= 0.70 then ts+=3 elseif relY >= 0.20 and relY <= 0.80 then ts+=1 end
            if sr > 0.40 then ts+=1 end
            table.insert(scored, { part=p, headScore=hs, torsoScore=ts, relY=relY, vol=v })
        end
        table.sort(scored, function(a,b) return a.headScore > b.headScore end)
        return scored
    end

    local function _estimateHead(model)
        local cache = _getGeomCache(model)
        local now = os.clock()
        if cache and cache.structHead and now - cache.structHeadTime < STRUCT_TTL then
            local part = cache.structHead
            if part.Parent and part:IsDescendantOf(model) then return part.Position end
        end
        local parts  = _collectParts(model)
        local scored = _scoreParts(parts)
        if #scored == 0 then return nil end
        local best = scored[1]
        if best.headScore <= 0 then return nil end
        if #scored >= 2 then
            local second = scored[2]
            if best.headScore == second.headScore
                and math.abs(best.part.Position.Y - second.part.Position.Y) < 0.5 then
                if second.part.Position.Y > best.part.Position.Y then best = second end
            end
        end
        -- Cache the selected part, then read its live position between rescans.
        if cache then cache.structHead = best.part; cache.structHeadTime = now end
        return best.part.Position
    end

    local function _estimateTorso(model)
        local cache = _getGeomCache(model)
        local now = os.clock()
        if cache and cache.structTorso and now - cache.structTorsoTime < STRUCT_TTL then
            local part = cache.structTorso
            if part.Parent and part:IsDescendantOf(model) then return part.Position end
        end
        local parts  = _collectParts(model)
        local scored = _scoreParts(parts)
        if #scored == 0 then return nil end
        table.sort(scored, function(a,b) return a.torsoScore > b.torsoScore end)
        local best = scored[1]
        if best.torsoScore <= 0 then return nil end
        if cache then cache.structTorso = best.part; cache.structTorsoTime = now end
        return best.part.Position
    end

    -- Returns world position for a body region
    function GeometryService.GetAimPos(char, region)
        if not char then return nil end
        region = region or "Head"
        if region == "ClosestPart" then region = "Head" end
        -- Bone/configured hitbox -> standard part -> attachment/joint/name.
        -- No Humanoid requirement: AnimationController-only rigs work too.
        local resolved = _getResolvedRegionPos(char, region)
        if resolved then return resolved end
        -- Step 2: Structural detection
        local cf, sz = GeometryService.GetCharBBox(char)
        if not cf or not sz then return nil end
        if not region or region == "Head" or region == "ClosestPart" then
            local hp = _estimateHead(char)
            if hp then return hp end
            return cf.Position + Vector3.new(0, sz.Y * 0.40, 0)
        end
        if region == "UpperTorso" or region == "Torso" then
            local tp = _estimateTorso(char)
            if tp then return tp end
        end
        -- Step 3: bbox offset fallback
        local frac = BBOX_OFFSETS[region] or 0.00
        if frac ~= 0.00 and sz.Y < math.max(sz.X, sz.Z) * 0.6 then frac = 0.00 end
        return cf.Position + Vector3.new(0, sz.Y * frac, 0)
    end

    function GeometryService.GetAnyPart(char)
        if not char then return nil end
        local cache = _getGeomCache(char)
        if cache then
            if cache.anyPart and cache.anyPart.Parent then return cache.anyPart end
            for part in pairs(cache.allParts) do
                if part and part.Parent then return part end
            end
        end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then return p end
        end
        return nil
    end

    -- Screen-space helpers
    function GeometryService.FOVOrigin()
        if ConfigService.Get("FOVMethod") == "Mouse" then
            local ok, ml = pcall(function() return UserInputService:GetMouseLocation() end)
            if ok and ml then return ml end
        end
        local cam = ctx.camera
        if not cam then return Vector2.new(0, 0) end
        local ok, vp = pcall(function() return cam.ViewportSize end)
        if not ok or not vp then return Vector2.new(0, 0) end
        return Vector2.new(vp.X / 2, vp.Y / 2)
    end

    function GeometryService.WorldToScreen(pos)
        if not pos then return nil end
        local ok, s = pcall(function() return ctx.camera:WorldToViewportPoint(pos) end)
        if ok and s and s.Z > 0 then return Vector2.new(s.X, s.Y) end
        return nil
    end

    function GeometryService.ScreenDistFromPos(pos)
        local sp = GeometryService.WorldToScreen(pos)
        if not sp then return math.huge end
        return (sp - GeometryService.FOVOrigin()).Magnitude
    end

    -- Projects all 8 OBB corners to screen using the full CFrame (handles rotated models).
    -- Accepts (bboxCFrame, sizeVector3) — corners are cf:PointToWorldSpace(±hx, ±hy, ±hz).
    -- Returns (minX, maxX, minY, maxY) or nil.
    function GeometryService.ProjectAABB(cf, sz)
        if not cf or not sz then return nil end
        local cam = ctx.camera
        if not cam then return nil end
        local hx, hy, hz = sz.X*0.5, sz.Y*0.5, sz.Z*0.5
        local sMinX, sMaxX, sMinY, sMaxY = math.huge, -math.huge, math.huge, -math.huge
        for xSign = -1, 1, 2 do
            local ox = xSign * hx
            for ySign = -1, 1, 2 do
                local oy = ySign * hy
                for zSign = -1, 1, 2 do
                    local oz = zSign * hz
                    -- PointToWorldSpace correctly handles rotated bboxCF
                    local worldCorner = cf:PointToWorldSpace(Vector3.new(ox, oy, oz))
                    local ok, sp = pcall(function()
                        return cam:WorldToViewportPoint(worldCorner)
                    end)
                    if ok and sp and sp.Z > 0 then
                        sMinX = math.min(sMinX, sp.X); sMaxX = math.max(sMaxX, sp.X)
                        sMinY = math.min(sMinY, sp.Y); sMaxY = math.max(sMaxY, sp.Y)
                    end
                end
            end
        end
        if sMinX == math.huge then return nil end
        return sMinX, sMaxX, sMinY, sMaxY
    end

    -- Normal box mode only needs the top and bottom of the character. Keeping the
    -- exact eight-corner path available makes it an explicit high-cost option.
    function GeometryService.ProjectTwoPoint(char, cf, sz)
        if not cf or not sz then return nil end
        local cam = ctx.camera
        if not cam then return nil end
        local halfY = sz.Y * 0.5
        local topWorld = cf.Position + Vector3.new(0, halfY, 0)
        local bottomWorld = cf.Position - Vector3.new(0, halfY, 0)
        local ok, top, bottom = pcall(function()
            return cam:WorldToViewportPoint(topWorld), cam:WorldToViewportPoint(bottomWorld)
        end)
        if not ok or not top or not bottom or top.Z <= 0 or bottom.Z <= 0 then return nil end
        local height = math.abs(bottom.Y - top.Y)
        if height < 1 then return nil end
        local width = height * 0.45
        local centerX = (top.X + bottom.X) * 0.5
        return centerX - width * 0.5, centerX + width * 0.5,
            math.min(top.Y, bottom.Y), math.max(top.Y, bottom.Y)
    end

    -- Closest region position to FOV origin
    local REGIONS = { "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso" }
    function GeometryService.ClosestRegionPos(char)
        local org = GeometryService.FOVOrigin()
        local best, bestD = nil, math.huge
        for _, region in ipairs(REGIONS) do
            local pos = GeometryService.GetAimPos(char, region)
            if pos then
                local ok, s = pcall(function() return ctx.camera:WorldToViewportPoint(pos) end)
                if ok and s and s.Z > 0 then
                    local d = (Vector2.new(s.X, s.Y) - org).Magnitude
                    if d < bestD then bestD = d; best = pos end
                end
            end
        end
        return best
    end

    -- Returns the aim-point based on config
    function GeometryService.GetTargetPos(char)
        if ConfigService.Get("ClosestPart") then
            return GeometryService.ClosestRegionPos(char) or GeometryService.GetCharCenter(char)
        else
            return GeometryService.GetAimPos(char, ConfigService.Get("TargetPart") or "Head")
                or GeometryService.GetCharCenter(char)
        end
    end

    function GeometryService.ScreenDist(char)
        return GeometryService.ScreenDistFromPos(GeometryService.GetTargetPos(char))
    end


    return GeometryService
end
