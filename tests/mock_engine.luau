-- Deliberately small deterministic engine shim, not a Roblox integration test.
local allSignals, bindings, queue = {}, {}, {}
local function signal()
    local s={listeners={}}
    function s:Connect(fn)
        local c={Connected=true,kind="RBXScriptConnection",fn=fn}
        function c:Disconnect() self.Connected=false end
        table.insert(self.listeners,c)
        return c
    end
    function s:Fire(...)
        for _,c in ipairs(table.clone(self.listeners)) do if c.Connected then c.fn(...) end end
    end
    table.insert(allSignals,s)
    return s
end
local nativeTypeof=typeof
local function typeof(v) return type(v)=="table" and v.kind or nativeTypeof(v) end
local function warn(...) print("WARN",...) end
local now=100
local function tick() return now end
local task={}
function task.spawn(fn,...) table.insert(queue,{fn=fn,args=table.pack(...)});return coroutine.create(fn) end
task.defer=task.spawn
function task.delay(_,fn,...) return task.spawn(fn,...) end
function task.wait() return 0 end
local function flush()
    local jobs=queue;queue={}
    for _,j in ipairs(jobs) do j.fn(table.unpack(j.args,1,j.args.n)) end
end
local vmeta={}
vmeta.__index=function(v,k)
    if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
    if k=="Dot" then return function(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end end
    if k=="Unit" then return v / v.Magnitude end
end
local Vector3={}
function Vector3.new(x,y,z) return setmetatable({X=x or 0,Y=y or 0,Z=z or 0,kind="Vector3"},vmeta) end
vmeta.__add=function(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
vmeta.__sub=function(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
vmeta.__mul=function(a,b) if type(a)=="number" then a,b=b,a end;return Vector3.new(a.X*b,a.Y*b,a.Z*b) end
vmeta.__div=function(a,b) return Vector3.new(a.X/b,a.Y/b,a.Z/b) end
vmeta.__unm=function(a) return Vector3.new(-a.X,-a.Y,-a.Z) end
vmeta.__eq=function(a,b) return a.X==b.X and a.Y==b.Y and a.Z==b.Z end
Vector3.zero=Vector3.new();Vector3.one=Vector3.new(1,1,1)
local Vector2={new=function(x,y) return {X=x or 0,Y=y or 0,kind="Vector2"} end}
local Color3={new=function(r,g,b) return {R=r or 0,G=g or 0,B=b or 0,kind="Color3"} end}
function Color3.fromRGB(r,g,b) return Color3.new(r/255,g/255,b/255) end
local CFrame={}
local cfMethods,cfMeta={},{}
cfMeta.__index=function(cf,k)
    if cfMethods[k] then return cfMethods[k] end
    if k=="LookVector" then return -cf.BackVector end
end
local function frame(position,right,up,back)
    return setmetatable({Position=position,RightVector=right,UpVector=up,BackVector=back,kind="CFrame"},cfMeta)
end
function CFrame.new(x,y,z)
    return frame(type(x)=="table" and x or Vector3.new(x,y,z),Vector3.new(1,0,0),Vector3.new(0,1,0),Vector3.new(0,0,1))
end
function CFrame.fromMatrix(position,right,up,back) return frame(position,right,up,back) end
function cfMethods:VectorToWorldSpace(v) return self.RightVector*v.X+self.UpVector*v.Y+self.BackVector*v.Z end
function cfMethods:PointToWorldSpace(v) return self.Position+self:VectorToWorldSpace(v) end
function cfMethods:PointToObjectSpace(v)
    local d=v-self.Position
    return Vector3.new(d:Dot(self.RightVector),d:Dot(self.UpVector),d:Dot(self.BackVector))
end
cfMeta.__mul=function(a,b)
    return frame(a:PointToWorldSpace(b.Position),a:VectorToWorldSpace(b.RightVector),a:VectorToWorldSpace(b.UpVector),a:VectorToWorldSpace(b.BackVector))
end
function CFrame.Angles(x,y,z)
    local sx,cx,sy,cy,sz,cz=math.sin(x),math.cos(x),math.sin(y),math.cos(y),math.sin(z),math.cos(z)
    local rx=frame(Vector3.zero,Vector3.new(1,0,0),Vector3.new(0,cx,sx),Vector3.new(0,-sx,cx))
    local ry=frame(Vector3.zero,Vector3.new(cy,0,-sy),Vector3.new(0,1,0),Vector3.new(sy,0,cy))
    local rz=frame(Vector3.zero,Vector3.new(cz,sz,0),Vector3.new(-sz,cz,0),Vector3.new(0,0,1))
    return rx*ry*rz
end
local UDim={new=function(s,o) return {Scale=s or 0,Offset=o or 0} end}
local UDim2={new=function(xs,xo,ys,yo) return {X=UDim.new(xs,xo),Y=UDim.new(ys,yo)} end}
function UDim2.fromOffset(x,y) return UDim2.new(0,x,0,y) end
function UDim2.fromScale(x,y) return UDim2.new(x,0,y,0) end
local Enum=setmetatable({},{__index=function(t,k)
    local category=setmetatable({},{__index=function(c,n) local e={Name=n,Value=100};rawset(c,n,e);return e end})
    rawset(t,k,category);return category
end})
local methods,meta={},{}
meta.__index=function(o,k)
    if methods[k] then return methods[k] end
    local v=o.props[k];if v~=nil then return v end
    for _,c in ipairs(o.children) do if c.Name==k then return c end end
    return nil
end
meta.__newindex=function(o,k,v)
    if k=="Parent" then
        local old=o.props.Parent
        if old then local i=table.find(old.children,o);if i then table.remove(old.children,i) end end
        o.props.Parent=v
        if v then table.insert(v.children,o) end
    else
        o.props[k]=v
        if (o.props.ClassName=="Part" or o.props.ClassName=="MeshPart") and k=="Position" then local cf=o.props.CFrame
            o.props.CFrame=cf and CFrame.fromMatrix(v,cf.RightVector,cf.UpVector,cf.BackVector) or CFrame.new(v)
        end
        if (o.props.ClassName=="Part" or o.props.ClassName=="MeshPart") and k=="CFrame" then o.props.Position=v.Position end
    end
end
local Instance={}
function Instance.new(class)
    local o=setmetatable({kind="Instance",children={},props={ClassName=class,Name=class}},meta)
    for _,key in ipairs({"Changed","AncestryChanged","DescendantAdded","DescendantRemoving","ChildAdded","ChildRemoved",
        "Destroying","Activated","FocusLost","InputBegan","InputEnded","InputChanged","CharacterAdded","CharacterRemoving",
        "PlayerAdded","PlayerRemoving","Heartbeat","RenderStepped","WindowFocusReleased"}) do o[key]=signal() end
    if class=="Part" then o.Position=Vector3.zero;o.Size=Vector3.one;o.Transparency=0;o.CFrame=CFrame.new() end
    return o
end
function methods:IsA(c)
    return self.ClassName==c or c=="Instance" or (c=="BasePart" and (self.ClassName=="Part" or self.ClassName=="MeshPart"))
        or (c=="Attachment" and self.ClassName=="Bone") or (c=="Accoutrement" and self.ClassName=="Accessory")
end
function methods:GetChildren() return table.clone(self.children) end
function methods:GetDescendants()
    local out={};local function visit(o) for _,c in ipairs(o.children) do table.insert(out,c);visit(c) end end
    visit(self);return out
end
function methods:FindFirstChild(n,recursive)
    for _,c in ipairs(self.children) do if c.Name==n then return c end end
    if recursive then for _,c in ipairs(self.children) do local hit=c:FindFirstChild(n,true);if hit then return hit end end end
end
function methods:FindFirstChildWhichIsA(c,recursive)
    for _,o in ipairs(recursive and self:GetDescendants() or self.children) do if o:IsA(c) then return o end end
end
methods.FindFirstChildOfClass=methods.FindFirstChildWhichIsA
function methods:IsDescendantOf(parent) local p=self.Parent;while p do if p==parent then return true end;p=p.Parent end;return false end
function methods:GetFullName() return self.Parent and self.Parent:GetFullName().."."..self.Name or self.Name end
function methods:GetPropertyChangedSignal(n) self.props.signals=self.props.signals or {};self.props.signals[n]=self.props.signals[n] or signal();return self.props.signals[n] end
function methods:GetAttribute(key) return self.props.attributes and self.props.attributes[key] end
function methods:SetAttribute(key,value)
    self.props.attributes=self.props.attributes or {};self.props.attributes[key]=value
end
function methods:Destroy()
    if self.props.destroyed then return end;self.props.destroyed=true
    self.Destroying:Fire()
    for _,c in ipairs(self:GetChildren()) do c:Destroy() end
    self.Parent=nil
    for _,v in pairs(self.props) do if type(v)=="table" and v.listeners then for _,c in ipairs(v.listeners) do c:Disconnect() end end end
end
function methods:WaitForChild(name) return assert(self:FindFirstChild(name),"Missing child "..name) end
function methods:GetFocusedTextBox() return nil end
function methods:BindToRenderStep(name,_,fn) assert(not bindings[name]);bindings[name]=fn end
function methods:UnbindFromRenderStep(name) bindings[name]=nil end
local game=Instance.new("DataModel");game.Name="game"
local services={}
function methods:GetService(name)
    if not services[name] then local s=Instance.new(name);s.Name=name;s.Parent=game;services[name]=s end
    return services[name]
end
local workspace=game:GetService("Workspace")
workspace.CurrentCamera=Instance.new("Camera");workspace.CurrentCamera.ViewportSize=Vector2.new(1280,720);workspace.CurrentCamera.CFrame=CFrame.new()
local player=Instance.new("Player");player.Name="Local";player.DisplayName="Local";player.UserId=1
player.Parent=game:GetService("Players");player.Neutral=true
game:GetService("Players").LocalPlayer=player
local pg=Instance.new("PlayerGui");pg.Name="PlayerGui";pg.Parent=player
function methods:GetPlayers()
    local list={};for _,p in ipairs(game:GetService("Players"):GetChildren()) do if p:IsA("Player") then list[#list+1]=p end end
    return list
end
function methods:GetPlayerFromCharacter(char)
    for _,p in ipairs(self:GetPlayers()) do if p.Character==char then return p end end
end
local RaycastParams={new=function() return {} end}
local passed=0
local function check(name,fn) fn();passed+=1;print("PASS",name) end
