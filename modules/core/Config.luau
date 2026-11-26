-- core/Config: isolated factory; dependencies are explicit parameters.
return function(ctx)
    local ConfigService = {}

    ConfigService._data = {
        -- Aimbot core
        Enabled           = true,
        LockOnPlayers     = true,
        LockOnNPCs        = false,
        TeamCheck         = false,
        WallCheck         = false,
        TargetPart        = "Head",
        ClosestPart       = false,
        FOV               = 350,
        FOVMethod         = "Screen",  -- "Screen" | "Mouse"
        LockRange         = 2000,
        AimMode           = "Camera",  -- "Camera" | "Mouse"
        SmoothX           = 100,
        SmoothY           = 100,
        HitChance         = 100,

        -- Prediction
        Prediction        = 0.02,
        BallisticSpeed    = 0,
        AutoProjectileSpeed = true,
        DropCompensation  = false,

        -- FOV display
        ShowFOV           = false,
        FOVFill           = false,

        -- Crosshair
        Crosshair         = false,
        CrosshairStyle    = "Cross",
        CrosshairSize     = 10,
        CrosshairGap      = 4,
        CrosshairThickness= 1,
        CrosshairColor    = Color3.fromRGB(255, 255, 255),
        CrosshairOutline  = false,

        -- ESP visuals
        Box               = false,
        Name              = false,
        Health            = false,
        Tracers           = false,
        Distance          = false,
        Skeleton          = false,
        Chams             = false,
        ChamsColor        = Color3.fromRGB(255, 50, 50),
        ChamsOutline      = Color3.fromRGB(255, 255, 255),
        ChamsFillTransp   = 0.6,
        ChamsOutlineTransp= 1,
        ChamsWallOnly     = false,
        AccurateBoxes     = false,
        ExactBoxes        = false,
        HighQualityVisibility = false,
        Accent            = Color3.fromRGB(0, 170, 255),


    }

    function ConfigService.Get(key)
        return ConfigService._data[key]
    end

    ConfigService.Defaults = table.clone(ConfigService._data)
    ConfigService.Ranges = {
        FOV={1,1000}, LockRange={0,10000}, SmoothX={1,100}, SmoothY={1,100},
        Prediction={0,0.5}, BallisticSpeed={0,10000}, HitChance={1,100},
        CrosshairSize={2,40}, CrosshairGap={0,20}, CrosshairThickness={1,6},
        ChamsFillTransp={0,1}, ChamsOutlineTransp={0,1},
    }
    ConfigService.Options = {
        AimMode={"Camera","Mouse"}, FOVMethod={"Screen","Mouse"},
        TargetPart={"Head","Torso","UpperTorso","LowerTorso","HumanoidRootPart"},
        CrosshairStyle={"Cross","Dot","Circle","Cross+Dot"},
    }

    local _configTypes = {}
    for key, value in pairs(ConfigService._data) do
        _configTypes[key] = typeof(value)
    end

    local _configListeners = {}
    function ConfigService.OnChanged(key, callback)
        if not ctx.alive or _configTypes[key] == nil or type(callback) ~= "function" then
            return function() end
        end
        local listeners = _configListeners[key] or {}
        _configListeners[key] = listeners
        local subscription = { callback = callback, active = true }
        listeners[#listeners + 1] = subscription
        return function()
            if not subscription.active then return end
            subscription.active = false
            for i = #listeners, 1, -1 do
                if listeners[i] == subscription then
                    table.remove(listeners, i)
                    break
                end
            end
        end
    end

    -- forceNotify reapplies subscribers after a config load even when the stored
    -- value did not change; normal UI writes retain change-only notification.
    function ConfigService.Set(key, value, forceNotify)
        if not ctx.alive then return false end
        local expected = _configTypes[key]
        if not expected then
            warn("[SwaX] Ignoring unknown configuration key: " .. tostring(key))
            return false
        end
        if expected == "number" and (type(value) ~= "number" or value ~= value or math.abs(value) == math.huge) then return false end
        if typeof(value) ~= expected then
            warn(string.format("[SwaX] Ignoring invalid %s value for %s", typeof(value), tostring(key)))
            return false
        end
        if key == "AimMode" and value ~= "Camera" and value ~= "Mouse" then
            warn("[SwaX] Ignoring invalid AimMode: " .. value)
            return false
        end
        local range = ConfigService.Ranges[key]
        if range then value = math.clamp(value, range[1], range[2]) end
        local options = ConfigService.Options[key]
        if options and not table.find(options, value) then return false end
        if ConfigService._data[key] == value and forceNotify ~= true then return true end
        ConfigService._data[key] = value
        local listeners = _configListeners[key]
        if listeners then
            -- Callbacks may disconnect themselves or register new subscribers.
            for _, subscription in ipairs(table.clone(listeners)) do
                if subscription.active then pcall(subscription.callback, value) end
            end
        end
        return true
    end

    function ConfigService.Clean()
        for _, listeners in pairs(_configListeners) do
            for _, subscription in ipairs(listeners) do subscription.active = false end
            table.clear(listeners)
        end
        table.clear(_configListeners)
    end

    return ConfigService
end
