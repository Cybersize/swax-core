-- Pure helpers shared by selection, aim and geometry; tested independently.
local CoreMath = { MAX_FLIGHT_TIME = 30 }

function CoreMath.IsFinite(value)
    return type(value)=="number" and value==value and math.abs(value)<math.huge
end

function CoreMath.ScreenDistanceSquared(point, origin)
    local x,y=point.X-origin.X,point.Y-origin.Y
    local distance=x*x+y*y
    return CoreMath.IsFinite(distance) and distance or math.huge
end

-- Preserve the old gain at 60 Hz, but make its decay rate time-based.
function CoreMath.SmoothingAlpha(percent, dt)
    if not CoreMath.IsFinite(dt) then dt=1/60 end
    if dt<=0 then return 0 end
    local gain=math.clamp(percent/100,0.01,1)
    if gain>=1 then return 1 end
    return 1-(1-gain)^(60*dt)
end

function CoreMath.MouseStep(dx,dy,dt,residualX,residualY)
    if not CoreMath.IsFinite(dt) or dt<=0 then return 0,0,0,0 end
    local limit=7200*dt -- pixels/second, not pixels/frame
    local scale=math.max(1,math.abs(dx)/limit,math.abs(dy)/limit)
    local x,y=dx/scale+residualX,dy/scale+residualY
    local ix=x>=0 and math.floor(x+0.5) or math.ceil(x-0.5)
    local iy=y>=0 and math.floor(y+0.5) or math.ceil(y-0.5)
    return ix,iy,x-ix,y-iy
end

-- Exact world AABB half-extents of an oriented rectangular part: |R| * h.
function CoreMath.WorldHalfExtents(cf,size)
    local r,u,l=cf.RightVector,cf.UpVector,cf.LookVector
    local x,y,z=size.X*0.5,size.Y*0.5,size.Z*0.5
    return Vector3.new(
        math.abs(r.X)*x+math.abs(u.X)*y+math.abs(l.X)*z,
        math.abs(r.Y)*x+math.abs(u.Y)*y+math.abs(l.Y)*z,
        math.abs(r.Z)*x+math.abs(u.Z)*y+math.abs(l.Z)*z)
end

-- Ascending coefficients. Derivative roots partition the interval into
-- monotonic pieces, so sign-bracketing does not skip a narrow low/high arc.
-- Testing the stationary points also finds tangent (maximum-range) roots.
local function evaluate(coefficients,x)
    local value,scale=0,0
    for index=#coefficients,1,-1 do
        value=value*x+coefficients[index]
        scale=scale*math.abs(x)+math.abs(coefficients[index])
    end
    return value,scale
end
local function polynomialRoots(coefficients,low,high)
    while #coefficients>1 and coefficients[#coefficients]==0 do table.remove(coefficients) end
    if #coefficients==1 then return {} end
    if #coefficients==2 then
        local root=-coefficients[1]/coefficients[2]
        return root>=low and root<=high and {root} or {}
    end
    local derivative={}
    for index=2,#coefficients do derivative[index-1]=(index-1)*coefficients[index] end
    local critical=polynomialRoots(derivative,low,high)
    local bounds={low}
    for _,root in ipairs(critical) do table.insert(bounds,root) end
    table.insert(bounds,high)
    local roots={}
    local function add(root)
        for _,existing in ipairs(roots) do
            if math.abs(existing-root)<=1e-7*math.max(1,math.abs(root)) then return end
        end
        table.insert(roots,root)
    end
    for _,x in ipairs(bounds) do
        local value,scale=evaluate(coefficients,x)
        if math.abs(value)<=scale*1e-10 then add(x) end
    end
    for index=1,#bounds-1 do
        local a,b=bounds[index],bounds[index+1]
        local fa,fb=evaluate(coefficients,a),evaluate(coefficients,b)
        if (fa<0 and fb>0) or (fa>0 and fb<0) then
            for _=1,80 do
                local mid=(a+b)*0.5
                local fm=evaluate(coefficients,mid)
                if fm==0 then a,b=mid,mid;break end
                if (fa<0 and fm>0) or (fa>0 and fm<0) then b=mid else a,fa=mid,fm end
                if b-a<=1e-12*math.max(1e-12,math.abs(mid)) then break end
            end
            add((a+b)*0.5)
        end
    end
    table.sort(roots)
    return roots
end

-- Constant target velocity and constant projectile acceleration; no drag.
-- |r + v*t - 0.5*a*t^2|^2 = speed^2*t^2.
-- Zero acceleration reduces to the ordinary moving-target quadratic.
function CoreMath.InterceptTime(displacement,velocity,speed,acceleration)
    if not CoreMath.IsFinite(speed) or speed<=0 then return nil end
    if displacement:Dot(displacement)<=1e-12 then return 0 end
    local half=-acceleration*0.5
    local coefficients={
        displacement:Dot(displacement),2*displacement:Dot(velocity),
        velocity:Dot(velocity)+2*displacement:Dot(half)-speed*speed,
        2*velocity:Dot(half),half:Dot(half),
    }
    local magnitude=0
    for _,value in ipairs(coefficients) do
        if not CoreMath.IsFinite(value) then return nil end
        magnitude=math.max(magnitude,math.abs(value))
    end
    if magnitude==0 then return 0 end
    for index,value in ipairs(coefficients) do coefficients[index]=value/magnitude end
    if coefficients[4]==0 and coefficients[5]==0 then
        -- Stable quadratic formula avoids cancellation for near/fast targets.
        local c,b,a=coefficients[1],coefficients[2],coefficients[3]
        local function supported(t)
            return CoreMath.IsFinite(t) and t>=0 and t<=CoreMath.MAX_FLIGHT_TIME
        end
        if a==0 then
            if b==0 then return nil end
            local t=-c/b
            return supported(t) and t or nil
        end
        local discriminant=b*b-4*a*c
        if discriminant<0 then return nil end
        local q=-0.5*(b+(b>=0 and 1 or -1)*math.sqrt(discriminant))
        local first=q/a
        local second=q~=0 and c/q or nil
        if supported(first) and supported(second) then return math.min(first,second) end
        if supported(first) then return first end
        return supported(second) and second or nil
    end
    local roots=polynomialRoots(coefficients,0,CoreMath.MAX_FLIGHT_TIME)
    return roots[1] -- nil means unreachable within the supported horizon
end

return CoreMath
