-- language: Luau, executor: Delta, target: Dandy's World, função: auto farm ichor + GUI liquid glass

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")

local lp = Players.LocalPlayer
local function getChar() return lp.Character end
local function getHum() local c = getChar() return c and c:FindFirstChildOfClass("Humanoid") end
local function getRoot() local c = getChar() return c and c:FindFirstChild("HumanoidRootPart") end

-- ───── utilidades de executor ─────
local protect_gui = (syn and syn.protect_gui) or (function(g) pcall(function() g.Name = tostring(math.random(100000,999999)) end) end)
local get_hui     = (typeof(gethui) == "function" and gethui) or (function() return game:GetService("CoreGui") end)
local fire_pp     = (typeof(fireproximityprompt) == "function" and fireproximityprompt) or nil

-- ───── estado global ─────
local farmActive   = false
local totalIchor   = 0
local statusMsg    = "Inativo"
local machineCooldowns = {}   -- [machine] = tick() do último uso
local COOLDOWN_SEC = 8        -- segundos antes de revisitar mesma máquina
local farmThread   = nil

-- ──────────────────────────────────────────────────────────────────────────────
-- 1.  DESCOBERTA DE MÁQUINAS  (heurística runtime — nomes reais são desconhecidos
--     sem o jogo aberto; a heurística identifica qualquer objeto que tenha um
--     ProximityPrompt cujo ActionText contenha palavras relacionadas a ichor,
--     ou ClickDetectors dentro de modelos cujos nomes contenham termos relevantes)
-- ──────────────────────────────────────────────────────────────────────────────
local ICHOR_KEYWORDS = {"ichor", "extract", "collect", "harvest", "machine", "tap"}

local function containsKeyword(str)
    local low = str:lower()
    for _, kw in ipairs(ICHOR_KEYWORDS) do
        if low:find(kw, 1, true) then return true end
    end
    return false
end

local function findPromptInModel(model)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ProximityPrompt") and containsKeyword(d.ActionText) then
            return d, "ProximityPrompt"
        end
    end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ClickDetector") then
            -- verifica se o modelo pai tem nome relevante
            if containsKeyword(model.Name) then
                return d, "ClickDetector"
            end
        end
    end
    return nil, nil
end

local function getMachines()
    local list = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") then
            local prompt, kind = findPromptInModel(obj)
            if prompt then
                -- calcula posição central do modelo
                local cf = obj:GetModelCenterPart()
                local pos = cf and cf.Position or (obj.PrimaryPart and obj.PrimaryPart.Position)
                if pos then
                    table.insert(list, {model = obj, prompt = prompt, kind = kind, position = pos})
                end
            end
        end
    end
    return list
end

-- ──────────────────────────────────────────────────────────────────────────────
-- 2.  PATHFINDING SUAVE
-- ──────────────────────────────────────────────────────────────────────────────
local PATH_PARAMS = {
    AgentHeight      = 5,
    AgentRadius      = 2,
    AgentCanJump     = true,
    AgentCanClimb    = false,
    WaypointSpacing  = 4,
}

local function walkTo(targetPos, stopCondition)
    local hum  = getHum()
    local root = getRoot()
    if not hum or not root then return false end

    local path = PathfindingService:CreatePath(PATH_PARAMS)
    local ok, err = pcall(function() path:ComputeAsync(root.Position, targetPos) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then
        -- fallback: MoveTo direto (distâncias curtas ou sem obstáculo)
        hum:MoveTo(targetPos)
        local t = tick()
        repeat task.wait(0.1) until
            (getRoot() and (getRoot().Position - targetPos).Magnitude < 5)
            or tick() - t > 10
            or (stopCondition and stopCondition())
        return true
    end

    local waypoints = path:GetWaypoints()
    for i, wp in ipairs(waypoints) do
        if stopCondition and stopCondition() then return false end
        hum = getHum()
        if not hum or hum.Health <= 0 then return false end
        if wp.Action == Enum.PathWaypointAction.Jump then
            hum.Jump = true
        end
        hum:MoveTo(wp.Position)
        -- espera chegar no waypoint ou timeout
        local t = tick()
        local moved = hum.MoveToFinished:Wait()
        -- se travar, recalcula do waypoint atual
        if tick() - t > 4 and i < #waypoints then
            return walkTo(targetPos, stopCondition)
        end
    end
    return true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- 3.  INTERAÇÃO COM MÁQUINA
-- ──────────────────────────────────────────────────────────────────────────────
local function interactMachine(entry)
    local prompt = entry.prompt
    local kind   = entry.kind
    if not prompt or not prompt.Parent then return false end

    if kind == "ProximityPrompt" then
        if fire_pp then
            fire_pp(prompt)
        else
            -- fallback via InputHoldBegin/End para ProximityPrompts com HoldDuration
            pcall(function()
                prompt:InputHoldBegin()
                task.wait(prompt.HoldDuration + 0.1)
                prompt:InputHoldEnd()
            end)
        end
        -- aguarda mudança de estado (prompt some ou atributo muda)
        local t = tick()
        repeat task.wait(0.15)
        until not prompt.Parent or tick() - t > 5
        return true

    elseif kind == "ClickDetector" then
        pcall(function()
            -- getconnections para disparar sem click físico
            if typeof(getconnections) == "function" then
                for _, conn in ipairs(getconnections(prompt.MouseClick)) do
                    if conn.Function then
                        pcall(conn.Function, lp)
                    end
                end
            else
                -- fallback nativo (pode não funcionar em todos executors)
                fireclickdetector(prompt)
            end
        end)
        task.wait(1)
        return true
    end
    return false
end

-- ──────────────────────────────────────────────────────────────────────────────
-- 4.  LOOP PRINCIPAL DO FARM
-- ──────────────────────────────────────────────────────────────────────────────
local function nearestMachine(machines)
    local root = getRoot()
    if not root then return nil end
    local best, bestDist = nil, math.huge
    for _, m in ipairs(machines) do
        local cd = machineCooldowns[m.model]
        if not cd or tick() - cd > COOLDOWN_SEC then
            local d = (root.Position - m.position).Magnitude
            if d < bestDist then
                best, bestDist = m, d
            end
        end
    end
    return best
end

local function farmLoop()
    while farmActive do
        local hum  = getHum()
        local root = getRoot()
        if not hum or hum.Health <= 0 or not root then
            task.wait(1)
        else
            local machines = getMachines()
            local target   = nearestMachine(machines)

            if not target then
                statusMsg = "Aguardando cooldowns..."
                task.wait(2)
            else
                statusMsg = "Indo para: " .. target.model.Name
                local dist = (root.Position - target.position).Magnitude
                if dist > 6 then
                    walkTo(target.position, function() return not farmActive end)
                end

                if farmActive then
                    statusMsg = "Coletando ichor..."
                    local ok = interactMachine(target)
                    if ok then
                        totalIchor += 1
                        machineCooldowns[target.model] = tick()
                        statusMsg = "Ichor: " .. totalIchor
                    end
                end
            end
        end
        task.wait(0.2)
    end
    statusMsg = "Inativo"
end

-- respawn automático
lp.CharacterAdded:Connect(function(char)
    if farmActive then
        task.wait(3) -- aguarda spawn completo
        farmThread = task.spawn(farmLoop)
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- 5.  GUI — LIQUID GLASS ESTILO iOS
-- ──────────────────────────────────────────────────────────────────────────────
local hui = get_hui()

-- Remove GUI anterior da mesma sessão se existir
for _, ch in ipairs(hui:GetChildren()) do
    if ch:IsA("ScreenGui") and ch:GetAttribute("DandysFarm") then
        ch:Destroy()
    end
end

-- BlurEffect no Lighting para efeito glassmorphism real
local blur = Lighting:FindFirstChildOfClass("BlurEffect")
if not blur then
    blur = Instance.new("BlurEffect")
    blur.Size = 0
    blur.Parent = Lighting
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name  = tostring(math.random(100000, 999999))
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui:SetAttribute("DandysFarm", true)
screenGui.Parent = hui
pcall(protect_gui, screenGui)

-- painel principal
local panel = Instance.new("Frame")
panel.Name             = "Panel"
panel.Size             = UDim2.new(0, 280, 0, 320)
panel.Position         = UDim2.new(0.5, -140, 0.5, -160)
panel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
panel.BackgroundTransparency = 0.18
panel.BorderSizePixel  = 0
panel.Parent           = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 22)
corner.Parent = panel

-- stroke (sombra suave)
local stroke = Instance.new("UIStroke")
stroke.Color       = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.6
stroke.Thickness   = 1.2
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = panel

-- sombra exterior via ImageLabel
local shadow = Instance.new("ImageLabel")
shadow.Name              = "Shadow"
shadow.Size              = UDim2.new(1, 40, 1, 40)
shadow.Position          = UDim2.new(0, -20, 0, -20)
shadow.BackgroundTransparency = 1
shadow.Image             = "rbxassetid://6015897843" -- sombra circular suave
shadow.ImageColor3       = Color3.fromRGB(0, 0, 0)
shadow.ImageTransparency = 0.7
shadow.ZIndex            = panel.ZIndex - 1
shadow.ScaleType         = Enum.ScaleType.Slice
shadow.SliceCenter       = Rect.new(49,49,450,450)
shadow.Parent            = panel

-- overlay de glass (gradiente sutil)
local glassOverlay = Instance.new("Frame")
glassOverlay.Size = UDim2.new(1, 0, 0.45, 0)
glassOverlay.Position = UDim2.new(0, 0, 0, 0)
glassOverlay.BackgroundColor3 = Color3.fromRGB(255,255,255)
glassOverlay.BackgroundTransparency = 0.75
glassOverlay.BorderSizePixel = 0
glassOverlay.Parent = panel
local glassCorner = Instance.new("UICorner")
glassCorner.CornerRadius = UDim.new(0, 22)
glassCorner.Parent = glassOverlay

-- ── BARRA DE TÍTULO + DRAG ────────────────────────────────────────────────────
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 44)
titleBar.Position = UDim2.new(0, 0, 0, 0)
titleBar.BackgroundTransparency = 1
titleBar.Parent = panel

local titleLabel = Instance.new("TextLabel")
titleLabel.Text             = "Dandy's Farm"
titleLabel.Font             = Enum.Font.GothamMedium
titleLabel.TextSize         = 15
titleLabel.TextColor3       = Color3.fromRGB(30, 30, 30)
titleLabel.BackgroundTransparency = 1
titleLabel.Size             = UDim2.new(1, -80, 1, 0)
titleLabel.Position         = UDim2.new(0, 16, 0, 0)
titleLabel.TextXAlignment   = Enum.TextXAlignment.Left
titleLabel.Parent           = titleBar

-- drag
local dragging, dragStart, startPos = false, nil, nil
titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging   = true
        dragStart  = input.Position
        startPos   = panel.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                  or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- ── BOTÕES DE CONTROLE ────────────────────────────────────────────────────────
local function makeControlBtn(text, color, xOffset)
    local btn = Instance.new("TextButton")
    btn.Text              = text
    btn.Font              = Enum.Font.GothamMedium
    btn.TextSize          = 12
    btn.TextColor3        = Color3.fromRGB(255,255,255)
    btn.BackgroundColor3  = color
    btn.BackgroundTransparency = 0.1
    btn.Size              = UDim2.new(0, 28, 0, 28)
    btn.Position          = UDim2.new(1, xOffset, 0, 8)
    btn.BorderSizePixel   = 0
    btn.Parent            = titleBar
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(1, 0)
    c.Parent = btn

    -- hover/tap feedback
    local function pressAnim()
        TweenService:Create(btn, TweenInfo.new(0.1, Enum.EasingStyle.Quad), {Size = UDim2.new(0,24,0,24), Position = UDim2.new(1, xOffset+2, 0, 10)}):Play()
    end
    local function releaseAnim()
        TweenService:Create(btn, TweenInfo.new(0.1, Enum.EasingStyle.Quad), {Size = UDim2.new(0,28,0,28), Position = UDim2.new(1, xOffset, 0, 8)}):Play()
    end
    btn.MouseButton1Down:Connect(pressAnim)
    btn.MouseButton1Up:Connect(releaseAnim)
    btn.TouchLongPress:Connect(pressAnim)
    return btn
end

local minimized    = false
local contentFrame -- definido abaixo

local minimizeBtn = makeControlBtn("−", Color3.fromRGB(255,196,0), -68)
local closeBtn    = makeControlBtn("×", Color3.fromRGB(255,59,48), -36)

closeBtn.MouseButton1Click:Connect(function()
    farmActive = false
    TweenService:Create(screenGui, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {Size = UDim2.new(0,0,0,0)}):Play()
    task.wait(0.22)
    screenGui:Destroy()
    -- remove blur ao fechar
    if blur then blur.Size = 0 end
end)

-- ── CONTEÚDO ──────────────────────────────────────────────────────────────────
contentFrame = Instance.new("Frame")
contentFrame.Name = "Content"
contentFrame.Size = UDim2.new(1, 0, 1, -44)
contentFrame.Position = UDim2.new(0, 0, 0, 44)
contentFrame.BackgroundTransparency = 1
contentFrame.Parent = panel

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 12)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = contentFrame

local padding = Instance.new("UIPadding")
padding.PaddingLeft   = UDim.new(0,16)
padding.PaddingRight  = UDim.new(0,16)
padding.PaddingTop    = UDim.new(0,8)
padding.Parent = contentFrame

-- label de status
local statusLabel = Instance.new("TextLabel")
statusLabel.Text              = "● " .. statusMsg
statusLabel.Font              = Enum.Font.Gotham
statusLabel.TextSize          = 13
statusLabel.TextColor3        = Color3.fromRGB(80, 80, 90)
statusLabel.BackgroundColor3  = Color3.fromRGB(245,245,250)
statusLabel.BackgroundTransparency = 0.3
statusLabel.Size              = UDim2.new(1, 0, 0, 36)
statusLabel.TextXAlignment    = Enum.TextXAlignment.Left
statusLabel.TextTruncate      = Enum.TextTruncate.AtEnd
statusLabel.LayoutOrder       = 1
statusLabel.BorderSizePixel   = 0
statusLabel.Parent            = contentFrame
local sc = Instance.new("UICorner") sc.CornerRadius = UDim.new(0,10) sc.Parent = statusLabel
local sp = Instance.new("UIPadding") sp.PaddingLeft = UDim.new(0,10) sp.Parent = statusLabel

-- label de contagem
local countLabel = Instance.new("TextLabel")
countLabel.Text           = "Ichor coletado: 0"
countLabel.Font           = Enum.Font.GothamMedium
countLabel.TextSize       = 22
countLabel.TextColor3     = Color3.fromRGB(0,122,255)
countLabel.BackgroundTransparency = 1
countLabel.Size           = UDim2.new(1, 0, 0, 32)
countLabel.TextXAlignment = Enum.TextXAlignment.Center
countLabel.LayoutOrder    = 2
countLabel.Parent         = contentFrame

-- separador
local sep = Instance.new("Frame")
sep.Size = UDim2.new(1, 0, 0, 1)
sep.BackgroundColor3 = Color3.fromRGB(200,200,210)
sep.BackgroundTransparency = 0.5
sep.BorderSizePixel = 0
sep.LayoutOrder = 3
sep.Parent = contentFrame

-- ── TOGGLE FARM (switch estilo iOS) ──────────────────────────────────────────
local toggleRow = Instance.new("Frame")
toggleRow.Size = UDim2.new(1, 0, 0, 44)
toggleRow.BackgroundTransparency = 1
toggleRow.LayoutOrder = 4
toggleRow.Parent = contentFrame

local toggleLabel = Instance.new("TextLabel")
toggleLabel.Text          = "Auto Farm"
toggleLabel.Font          = Enum.Font.GothamMedium
toggleLabel.TextSize      = 15
toggleLabel.TextColor3    = Color3.fromRGB(30,30,30)
toggleLabel.BackgroundTransparency = 1
toggleLabel.Size          = UDim2.new(1, -60, 1, 0)
toggleLabel.TextXAlignment = Enum.TextXAlignment.Left
toggleLabel.Parent        = toggleRow

-- track do switch
local switchTrack = Instance.new("Frame")
switchTrack.Size             = UDim2.new(0, 50, 0, 30)
switchTrack.Position         = UDim2.new(1, -50, 0.5, -15)
switchTrack.BackgroundColor3 = Color3.fromRGB(200,200,200)
switchTrack.BorderSizePixel  = 0
switchTrack.Parent           = toggleRow
local stc = Instance.new("UICorner") stc.CornerRadius = UDim.new(1,0) stc.Parent = switchTrack

-- thumb do switch
local switchThumb = Instance.new("Frame")
switchThumb.Size             = UDim2.new(0, 26, 0, 26)
switchThumb.Position         = UDim2.new(0, 2, 0, 2)
switchThumb.BackgroundColor3 = Color3.fromRGB(255,255,255)
switchThumb.BorderSizePixel  = 0
switchThumb.Parent           = switchTrack
local sthu = Instance.new("UICorner") sthu.CornerRadius = UDim.new(1,0) sthu.Parent = switchThumb

local function setToggle(active)
    local trackColor = active and Color3.fromRGB(52,199,89) or Color3.fromRGB(200,200,200)
    local thumbX     = active and UDim2.new(0,22,0,2) or UDim2.new(0,2,0,2)
    TweenService:Create(switchTrack, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {BackgroundColor3 = trackColor}):Play()
    TweenService:Create(switchThumb, TweenInfo.new(0.2, Enum.EasingStyle.Sine), {Position = thumbX}):Play()
end

local switchBtn = Instance.new("TextButton")
switchBtn.Text               = ""
switchBtn.BackgroundTransparency = 1
switchBtn.Size               = UDim2.new(0,50,0,30)
switchBtn.Position           = UDim2.new(1,-50,0.5,-15)
switchBtn.Parent             = toggleRow
switchBtn.ZIndex             = switchTrack.ZIndex + 1

switchBtn.MouseButton1Click:Connect(function()
    farmActive = not farmActive
    setToggle(farmActive)
    if farmActive then
        farmThread = task.spawn(farmLoop)
        blur.Size  = 8  -- blur sutil quando farm ativo
    else
        if blur then blur.Size = 0 end
    end
end)

-- ── LABEL MÁQUINA ATUAL ───────────────────────────────────────────────────────
local machineLabel = Instance.new("TextLabel")
machineLabel.Text           = "Máquina: —"
machineLabel.Font           = Enum.Font.Gotham
machineLabel.TextSize       = 12
machineLabel.TextColor3     = Color3.fromRGB(120,120,135)
machineLabel.BackgroundTransparency = 1
machineLabel.Size           = UDim2.new(1, 0, 0, 20)
machineLabel.TextXAlignment = Enum.TextXAlignment.Left
machineLabel.LayoutOrder    = 5
machineLabel.Parent         = contentFrame

-- ── MINIMIZAR ────────────────────────────────────────────────────────────────
minimizeBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    local targetH = minimized and 44 or 320
    TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Quad), {
        Size = UDim2.new(0, 280, 0, targetH)
    }):Play()
    contentFrame.Visible = not minimized
end)

-- ── ANIMAÇÃO DE ENTRADA ───────────────────────────────────────────────────────
panel.Position = UDim2.new(0.5, -140, 1, 20)  -- começa abaixo da tela
panel.BackgroundTransparency = 1
TweenService:Create(panel, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
    Position = UDim2.new(0.5, -140, 0.5, -160),
    BackgroundTransparency = 0.18,
}):Play()

-- ── LOOP DE ATUALIZAÇÃO DA GUI ────────────────────────────────────────────────
task.spawn(function()
    while screenGui and screenGui.Parent do
        pcall(function()
            countLabel.Text  = "Ichor coletado: " .. totalIchor
            statusLabel.Text = "● " .. statusMsg
            -- cor do dot de status
            if farmActive then
                statusLabel.TextColor3 = Color3.fromRGB(52,199,89)
            else
                statusLabel.TextColor3 = Color3.fromRGB(180,180,190)
            end
            -- nome da máquina atual extraído do statusMsg
            if statusMsg:find("Indo para:") or statusMsg:find("Coletando") then
                machineLabel.Text = "Máquina: " .. (statusMsg:match(": (.+)") or "—")
            else
                machineLabel.Text = "Máquina: —"
            end
        end)
        task.wait(0.25)
    end
end)

-- ── NOTA DE DERIVAÇÃO (única coisa não verificável sem o jogo aberto) ─────────
-- Os nomes reais dos Modelos de máquina em Dandy's World não podem ser confirmados
-- sem o cliente aberto; a heurística em getMachines() os descobre por ProximityPrompt.ActionText
-- em runtime. Se nenhuma máquina for encontrada, abra o Explorer do executor,
-- inspecione um objeto interagível e confirme se o ActionText contém os keywords acima.
