local function near(a,b,tolerance)
    assert(math.abs(a-b)<=(tolerance or 1e-6),string.format("Expected %.12g, got %.12g",b,a))
end
local function vectorNear(a,b,tolerance)
    near(a.X,b.X,tolerance);near(a.Y,b.Y,tolerance);near(a.Z,b.Z,tolerance)
end

check("FOV score does not shrink with world distance",function()
    local get,screen,origin=GeometryService.GetTargetPos,GeometryService.WorldToScreen,GeometryService.FOVOrigin
    GeometryService.WorldToScreen=function() return Vector2.new(100,0) end
    GeometryService.FOVOrigin=function() return Vector2.new(0,0) end
    for _,distance in ipairs({10,100,1000}) do
        GeometryService.GetTargetPos=function() return Vector3.new(distance,0,0) end
        near(TargetSelector.GetSelectionScoreSquared({}),10000)
    end
    GeometryService.GetTargetPos,GeometryService.WorldToScreen,GeometryService.FOVOrigin=get,screen,origin
end)
check("Selection accepts inside/on-circle points and rejects outside points",function()
    local all,position,screen,origin=CharacterRegistry.GetAll,GeometryService.GetTargetPos,GeometryService.WorldToScreen,GeometryService.FOVOrigin
    local char=Instance.new("Model");char.Parent=workspace
    local entry={char=char,name="FOV target"};local pixel=100
    CharacterRegistry.GetAll=function() return {entry} end
    GeometryService.GetTargetPos=function() return Vector3.new(1000,0,0) end
    GeometryService.WorldToScreen=function() return Vector2.new(pixel,0) end
    GeometryService.FOVOrigin=function() return Vector2.new(0,0) end
    local oldFov=ConfigService.Get("FOV");ConfigService.Set("FOV",350)
    assert(TargetSelector.GetBestTarget()==entry)
    pixel=350;assert(TargetSelector.GetBestTarget()==entry)
    pixel=350.01;assert(TargetSelector.GetBestTarget()==nil)
    CharacterRegistry.GetAll,GeometryService.GetTargetPos,GeometryService.WorldToScreen,GeometryService.FOVOrigin=all,position,screen,origin
    ConfigService.Set("FOV",oldFov);char:Destroy()
end)
check("Pixel-distance calculation is translation invariant",function()
    near(CoreMath.ScreenDistanceSquared(Vector2.new(13,24),Vector2.new(10,20)),25)
end)
check("Smoothing retains the old 60Hz gain",function() near(CoreMath.SmoothingAlpha(10,1/60),0.1) end)
check("Smoothing progress is the same at 30,60,144 and 240 FPS",function()
    local expected=0.99^60
    for _,fps in ipairs({30,60,144,240}) do
        local remaining=1
        for _=1,fps do remaining*=1-CoreMath.SmoothingAlpha(1,1/fps) end
        near(remaining,expected,1e-12)
    end
end)
check("Smoothing handles zero dt and snap gain",function()
    near(CoreMath.SmoothingAlpha(50,0),0);near(CoreMath.SmoothingAlpha(100,1/144),1)
    near(CoreMath.SmoothingAlpha(10,0/0),0.1)
end)
check("Actual camera callback applies time-based yaw smoothing",function()
    local original=LockController.GetLockedTarget
    local char={};local target=Vector3.new(10,0,-100);local startAngle=math.atan2(10,100)
    local oldX,oldY=ConfigService.Get("SmoothX"),ConfigService.Get("SmoothY")
    local oldMode=ConfigService.Get("AimMode");local oldFrame=Camera.CFrame
    LockController.GetLockedTarget=function() return {char=char} end
    ConfigService.Set("SmoothX",1);ConfigService.Set("SmoothY",1);ConfigService.Set("AimMode","Camera")
    for _,fps in ipairs({30,60,144}) do
        Camera.CFrame=CFrame.new();AimController.SetTarget(target,char)
        for _=1,fps do bindings._SwaXCamAim(1/fps) end
        local p=Camera.CFrame:PointToObjectSpace(target)
        near(math.atan2(p.X,-p.Z),startAngle*0.99^60,1e-8)
    end
    AimController.ClearTarget();LockController.GetLockedTarget=original;Camera.CFrame=oldFrame
    ConfigService.Set("SmoothX",oldX);ConfigService.Set("SmoothY",oldY);ConfigService.Set("AimMode",oldMode)
end)
check("Mouse speed cap is measured per second, not per frame",function()
    for _,fps in ipairs({30,60,144,240}) do
        local sum,rx,ry=0,0,0
        for _=1,fps do local dx,dy;dx,dy,rx,ry=CoreMath.MouseStep(100000,0,1/fps,rx,ry);sum+=dx end
        near(sum,7200,1)
    end
end)
check("Mouse subpixel motion accumulates instead of being discarded",function()
    local sum,rx,ry=0,0,0
    for _=1,10 do local dx,dy;dx,dy,rx,ry=CoreMath.MouseStep(0.1,0,1/144,rx,ry);sum+=dx end
    near(sum,1);near(rx,0,1e-12)
end)
check("Rotated 10x2x2 part has a 2x10x2 world box",function()
    local rig=Instance.new("Model");rig.Parent=workspace
    local part=Instance.new("Part");part.Size=Vector3.new(10,2,2)
    part.CFrame=CFrame.Angles(0,0,math.pi/2);part.Parent=rig
    local _,size=GeometryService.GetCharBBox(rig)
    vectorNear(size,Vector3.new(2,10,2));rig:Destroy()
end)
check("Arbitrary-rotation extents match all eight transformed corners",function()
    local cf=CFrame.new(5,2,8)*CFrame.Angles(0.43,0.71,-0.29)
    local size=Vector3.new(10,2,3);local expected=Vector3.zero
    local maxX,maxY,maxZ=0,0,0
    for x=-1,1,2 do for y=-1,1,2 do for z=-1,1,2 do
        local p=cf:VectorToWorldSpace(Vector3.new(size.X*x/2,size.Y*y/2,size.Z*z/2))
        maxX=math.max(maxX,math.abs(p.X));maxY=math.max(maxY,math.abs(p.Y));maxZ=math.max(maxZ,math.abs(p.Z))
    end end end
    expected=Vector3.new(maxX,maxY,maxZ)
    vectorNear(CoreMath.WorldHalfExtents(cf,size),expected)
end)
local function interceptCheck(r,v,s,a,expected)
    local t=CoreMath.InterceptTime(r,v,s,a)
    assert(t~=nil,"Expected a reachable intercept")
    if expected then near(t,expected,1e-6) end
    if t>0 then
        local aim=r+v*t-a*(0.5*t*t)
        near(aim.Magnitude/t,s,1e-5)
        local impact=aim.Unit*s*t+a*(0.5*t*t)
        vectorNear(impact,r+v*t,1e-5)
    end
end
check("Stationary projectile intercept",function() interceptCheck(Vector3.new(100,0,0),Vector3.zero,100,Vector3.zero,1) end)
check("Receding-target intercept fixes the audited underlead",function() interceptCheck(Vector3.new(100,0,0),Vector3.new(50,0,0),100,Vector3.zero,2) end)
check("Approaching-target intercept",function() interceptCheck(Vector3.new(100,0,0),Vector3.new(-50,0,0),100,Vector3.zero,2/3) end)
check("Lateral-target intercept",function() interceptCheck(Vector3.new(100,0,0),Vector3.new(0,50,0),100,Vector3.zero,100/math.sqrt(7500)) end)
check("Uncatchable target has no invented intercept",function() assert(CoreMath.InterceptTime(Vector3.new(100,0,0),Vector3.new(150,0,0),100,Vector3.zero)==nil) end)
check("Degenerate linear intercept is handled",function()
    interceptCheck(Vector3.new(100,0,0),Vector3.new(-100,0,0),100,Vector3.zero,0.5)
    assert(CoreMath.InterceptTime(Vector3.new(100,0,0),Vector3.new(100,0,0),100,Vector3.zero)==nil)
end)
check("Projectile solver chooses the first gravitational arc",function()
    local t=math.sqrt(2*(10000-math.sqrt(100000000-4000000))/400)
    interceptCheck(Vector3.new(100,0,0),Vector3.zero,100,Vector3.new(0,-20,0),t)
end)
check("Moving-target gravitational intercept satisfies the trajectory equation",function()
    interceptCheck(Vector3.new(100,10,-20),Vector3.new(20,2,-5),100,Vector3.new(0,-20,0))
end)
check("Maximum-range tangent trajectory is not skipped",function()
    interceptCheck(Vector3.new(500,0,0),Vector3.zero,100,Vector3.new(0,-20,0),math.sqrt(2)*5)
end)
check("Out-of-range gravity shot is rejected",function()
    assert(CoreMath.InterceptTime(Vector3.new(501,0,0),Vector3.zero,100,Vector3.new(0,-20,0))==nil)
end)
check("Invalid speeds and flight-horizon limits are safe",function()
    for _,speed in ipairs({0,-10,0/0,math.huge}) do assert(CoreMath.InterceptTime(Vector3.new(10,0,0),Vector3.zero,speed,Vector3.zero)==nil) end
    near(CoreMath.InterceptTime(Vector3.new(3000,0,0),Vector3.zero,100,Vector3.zero),30)
    assert(CoreMath.InterceptTime(Vector3.new(3001,0,0),Vector3.zero,100,Vector3.zero)==nil)
    near(CoreMath.InterceptTime(Vector3.zero,Vector3.zero,100,Vector3.zero),0)
end)
check("Prediction uses the selected aim point and exact flight time",function()
    local rig=Instance.new("Model");rig.Parent=workspace
    local head=Instance.new("Part");head.Name="Head";head.Position=Vector3.new(100,0,0);head.Parent=rig
    local root=Instance.new("Part");root.Name="HumanoidRootPart";root.Position=Vector3.new(100,-3,0)
    root.AssemblyLinearVelocity=Vector3.new(50,0,0);root.Parent=rig;rig.PrimaryPart=root
    local oldSpeed,oldPrediction,oldDrop=ConfigService.Get("BallisticSpeed"),ConfigService.Get("Prediction"),ConfigService.Get("DropCompensation")
    local oldFrame=Camera.CFrame;Camera.CFrame=CFrame.new()
    ConfigService.Set("BallisticSpeed",100);ConfigService.Set("Prediction",0);ConfigService.Set("DropCompensation",false)
    vectorNear(TargetSelector.PredictPos(rig),Vector3.new(200,0,0),1e-5)
    ConfigService.Set("Prediction",0.02)
    vectorNear(TargetSelector.PredictPos(rig),Vector3.new(202,0,0),1e-5)
    ConfigService.Set("BallisticSpeed",oldSpeed);ConfigService.Set("Prediction",oldPrediction);ConfigService.Set("DropCompensation",oldDrop)
    Camera.CFrame=oldFrame;rig:Destroy()
end)
check("Intercept solver handles near targets and invalid vectors",function()
    interceptCheck(Vector3.new(0.001,0,0),Vector3.zero,10000,Vector3.zero,1e-7)
    assert(CoreMath.InterceptTime(Vector3.new(0/0,0,0),Vector3.zero,100,Vector3.zero)==nil)
end)
check("120 constructed moving-target trajectories satisfy impact equations",function()
    for _,g in ipairs({0,20}) do for i=1,60 do
        local t=0.2+(i%20)*0.1
        local speed=100+(i%9)*10
        local acceleration=Vector3.new(0,-g,0)
        local velocity=Vector3.new(10*math.sin(i*0.3),3*math.cos(i),7*math.cos(i*0.5))
        local direction=Vector3.new(math.sin(i),0.5*math.cos(i*0.7),-1).Unit
        local displacement=direction*speed*t+acceleration*(0.5*t*t)-velocity*t
        interceptCheck(displacement,velocity,speed,acceleration)
    end end
end)
local function animatedRig()
    local rig=Instance.new("Model");rig.Parent=workspace
    local driver=Instance.new("Part");driver.Name="Driver";driver.Parent=rig
    local chest=Instance.new("Bone");chest.Name="Spine";chest.TransformedWorldCFrame=CFrame.new(1,2,3);chest.Parent=driver
    local head=Instance.new("Bone");head.Name="mixamorig:Head";head.TransformedWorldCFrame=CFrame.new(5,1,0);head.Parent=chest
    return rig,chest,head
end
check("Skeleton follows actual animated bone endpoints",function()
    local rig,chest,head=animatedRig();local segments=GeometryService.GetSkeletonSegments(rig)
    assert(#segments==1);vectorNear(segments[1][1],chest.TransformedWorldCFrame.Position);vectorNear(segments[1][2],head.TransformedWorldCFrame.Position)
    head.TransformedWorldCFrame=CFrame.new(6,0,0)
    segments=GeometryService.GetSkeletonSegments(rig);vectorNear(segments[1][2],Vector3.new(6,0,0));rig:Destroy()
end)
check("Unknown disconnected rigs do not draw invented skeletons",function()
    local rig=Instance.new("Model");rig.Parent=workspace
    local part=Instance.new("Part");part.Name="UnmappedMesh";part.Parent=rig
    assert(#GeometryService.GetSkeletonSegments(rig)==0);rig:Destroy()
end)
check("Nested R6 body parts still produce real segments",function()
    local rig=Instance.new("Model");rig.Parent=workspace
    local folder=Instance.new("Folder");folder.Parent=rig
    local head=Instance.new("Part");head.Name="Head";head.Position=Vector3.new(0,5,0);head.Parent=folder
    local torso=Instance.new("Part");torso.Name="Torso";torso.Position=Vector3.new(0,3,0);torso.Parent=folder
    local segments=GeometryService.GetSkeletonSegments(rig);assert(#segments==1)
    vectorNear(segments[1][1],head.Position);vectorNear(segments[1][2],torso.Position);rig:Destroy()
end)
check("Skeleton topology invalidates when a bone is streamed in or removed",function()
    local rig,chest,head=animatedRig();assert(#GeometryService.GetSkeletonSegments(rig)==1)
    local arm=Instance.new("Bone");arm.Name="UpperArm";arm.TransformedWorldCFrame=CFrame.new(-2,2,3);arm.Parent=chest
    rig.DescendantAdded:Fire(arm);assert(#GeometryService.GetSkeletonSegments(rig)==2)
    rig.DescendantRemoving:Fire(arm);arm.Parent=nil;assert(#GeometryService.GetSkeletonSegments(rig)==1)
    arm:Destroy();rig:Destroy()
end)
check("Skeleton drawing pool grows only to the real segment count",function()
    local rig=animatedRig();local old=ConfigService.Get("Skeleton");ConfigService.Set("Skeleton",true)
    local getAll=CharacterRegistry.GetAll;CharacterRegistry.GetAll=function() return {{char=rig,name="Skeleton test"}} end
    local before=#drawingObjects
    VisualDebug.UpdateState(0.1)
    local allocated=0
    for index=before+1,#drawingObjects do if drawingObjects[index].kind=="Line" then allocated+=1 end end
    assert(allocated==1)
    CharacterRegistry.GetAll=getAll;ConfigService.Set("Skeleton",old);rig:Destroy()
end)
check("Motor6D skeletons read live joint endpoints",function()
    local rig=Instance.new("Model");rig.Parent=workspace
    local torso=Instance.new("Part");torso.Name="Torso";torso.Position=Vector3.new(0,3,0);torso.Parent=rig
    local head=Instance.new("Part");head.Name="Head";head.Position=Vector3.new(0,5,0);head.Parent=rig
    local neck=Instance.new("Motor6D");neck.Name="Neck";neck.Part0=torso;neck.Part1=head;neck.Parent=torso
    local segments=GeometryService.GetSkeletonSegments(rig);assert(#segments==1)
    vectorNear(segments[1][1],torso.Position);vectorNear(segments[1][2],head.Position)
    head.Position=Vector3.new(1,4,0);segments=GeometryService.GetSkeletonSegments(rig)
    vectorNear(segments[1][2],head.Position);rig:Destroy()
end)
check("Cosmetic and weapon bones are excluded from skeleton topology",function()
    local rig,chest=animatedRig()
    local accessory=Instance.new("Accessory");accessory.Parent=rig
    local handle=Instance.new("Part");handle.Parent=accessory
    local root=Instance.new("Bone");root.Name="Spine";root.TransformedWorldCFrame=CFrame.new(10,0,0);root.Parent=handle
    local tip=Instance.new("Bone");tip.Name="Head";tip.TransformedWorldCFrame=CFrame.new(11,0,0);tip.Parent=root
    assert(#GeometryService.GetSkeletonSegments(rig)==1);rig:Destroy()
end)
check("Skeleton segment count is bounded for complex rigs",function()
    local rig,chest=animatedRig()
    for i=1,80 do
        local b=Instance.new("Bone");b.Name=string.format("UpperArm%03d",i)
        b.TransformedWorldCFrame=CFrame.new(i+1,2,3);b.Parent=chest
    end
    assert(#GeometryService.GetSkeletonSegments(rig)==GeometryService.SKELETON_LIMIT)
    rig:Destroy()
end)
