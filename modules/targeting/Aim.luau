-- targeting/Aim: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, LockController, TargetSelector, CoreMath)
    local RunService=ctx.services.RunService
    local UserInputService=ctx.services.UserInputService
    local AimController = {}

    local _aimTarget  = nil  -- world position to aim at this frame
    local _aimCharacter = nil
    local _mouseAimWarned = false
    local _mouseResidualX, _mouseResidualY = 0, 0

    function AimController.SetTarget(pos, char)
        if char ~= _aimCharacter then _mouseResidualX, _mouseResidualY = 0, 0 end
        _aimTarget, _aimCharacter = pos, char
    end
    function AimController.ClearTarget()
        _aimTarget, _aimCharacter = nil, nil
        _mouseResidualX, _mouseResidualY = 0, 0
    end


    -- Run at Last priority so our aim fires AFTER any weapon/ADS camera script.
    -- The selected mode controls only aim output; both modes share prediction/lock.
    RunService:BindToRenderStep("_SwaXCamAim", Enum.RenderPriority.Last.Value, function(dt)
        if not _aimTarget then return end
        local locked = LockController.GetLockedTarget()
        if not ctx.alive or not ConfigService.Get("Enabled") or not locked
            or locked.char ~= _aimCharacter then
            AimController.ClearTarget()
            return
        end
        local cam = ctx.camera
        if not cam then return end
        pcall(function()
            local sx = CoreMath.SmoothingAlpha(ConfigService.Get("SmoothX"), dt)
            local sy = CoreMath.SmoothingAlpha(ConfigService.Get("SmoothY"), dt)
            if not (sx < math.huge and sy < math.huge) then return end
            if ConfigService.Get("AimMode") == "Mouse" then
                local moveMouse = mousemoverel
                if type(moveMouse) ~= "function" then
                    if not _mouseAimWarned then
                        _mouseAimWarned = true
                        warn("[SwaX] Mouse aim is unavailable: mousemoverel is not supported. Choose Camera in Aim Mode.")
                    end
                    return
                end
                _mouseAimWarned = false
                local point, onScreen = cam:WorldToViewportPoint(_aimTarget)
                local vp = cam.ViewportSize
                if not onScreen or not (point.Z > 0 and point.Z < math.huge)
                    or not (vp.X > 0 and vp.X < math.huge and vp.Y > 0 and vp.Y < math.huge)
                    or not (point.X >= 0 and point.X <= vp.X and point.Y >= 0 and point.Y <= vp.Y) then return end
                local originX, originY = vp.X / 2, vp.Y / 2
                if UserInputService.MouseBehavior == Enum.MouseBehavior.Default then
                    -- Viewport and mouse coordinates include the topbar on desktop.
                    -- Use the real cursor for free movement so the error converges.
                    local cursor = UserInputService:GetMouseLocation()
                    originX, originY = cursor.X, cursor.Y
                end
                local dx, dy = (point.X - originX) * sx, (point.Y - originY) * sy
                if not (math.abs(dx) < math.huge and math.abs(dy) < math.huge) then return end
                -- Rate limit is time-based; retain subpixel motion instead of
                -- discarding it on high-refresh clients.
                dx, dy, _mouseResidualX, _mouseResidualY = CoreMath.MouseStep(
                    dx, dy, dt, _mouseResidualX, _mouseResidualY)
                if dx ~= 0 or dy ~= 0 then moveMouse(dx, dy) end
                return
            end
            _mouseResidualX, _mouseResidualY = 0, 0
            local cf = cam.CFrame
            local offset = cf:PointToObjectSpace(_aimTarget)
            if offset.Z >= 0 then return end
            local horizontalSquared = offset.X * offset.X + offset.Z * offset.Z
            if not (horizontalSquared + offset.Y * offset.Y < math.huge) then return end
            local yaw = -math.atan2(offset.X, -offset.Z) * sx
            local pitch = math.atan2(offset.Y, math.sqrt(horizontalSquared)) * sy
            if not (math.abs(yaw) < math.huge and math.abs(pitch) < math.huge) then return end
            cam.CFrame = cf * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
        end)
    end)

    ctx.maid:Give(function() RunService:UnbindFromRenderStep("_SwaXCamAim") end)

    -- Update aim each frame — called from main render loop
    function AimController.Update()
        local locked = LockController.GetLockedTarget()
        if not ctx.alive or not ConfigService.Get("Enabled") or not locked then
            AimController.ClearTarget()
            return
        end
        -- Hit chance gates this aim update. A skipped update must not keep steering
        -- toward a cached position from an earlier frame or target.
        if ConfigService.Get("HitChance") < 100 then
            if math.random(1, 100) > ConfigService.Get("HitChance") then
                AimController.ClearTarget()
                return
            end
        end
        local tpos = TargetSelector.PredictPos(locked.char)
        if not tpos then
            AimController.ClearTarget()
            return
        end
        AimController.SetTarget(tpos, locked.char)
    end

    return AimController
end
