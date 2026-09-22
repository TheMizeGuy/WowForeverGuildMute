-- WoW Forever Guild Mute: the minimap button. A click opens a small menu (hiding on or off, and
-- the settings page); a drag moves the button around the minimap's edge. The button is only made
-- when it is shown, and it runs code only while it is being dragged.

local _, ns = ...
local settings = ns.settings

local ICON = "Interface\\Icons\\Spell_Holy_Silence"

local button

local function Position()
    local angle = math.rad(settings.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function Drag()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local angle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    settings.minimapAngle = math.floor(angle % 360 + 0.5)
    Position()
end

local function OpenMenu()
    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateTitle("Guild Mute")
        root:CreateCheckbox("Hide chat from matching guilds", function()
            return settings.enabled
        end, function()
            settings.enabled = not settings.enabled
            ns.SettingsChanged(true)
        end)
        root:CreateButton("Settings", function()
            ns.OpenOptions()
        end)
    end)
end

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Guild Mute")
    GameTooltip:AddLine(settings.enabled and "Hiding chat from matching guilds." or "Off: all chat is shown.", 1, 1, 1)
    GameTooltip:AddLine("Click for options. Drag to move.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function Create()
    button = CreateFrame("Button", "GuildMuteMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(ICON)
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")
    button:SetScript("OnClick", OpenMenu)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
    button:SetScript("OnDragStart", function(self)
        GameTooltip_Hide()
        self:SetScript("OnUpdate", Drag)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        ns.SaveSettings()
    end)
end

-- Shows, places and greys out (while hiding is off) the button to match the settings.
function ns.UpdateMinimapButton()
    if not settings.minimap then
        if button then
            button:Hide()
        end
        return
    end
    if not button then
        Create()
    end
    Position()
    button.icon:SetDesaturated(not settings.enabled)
    button:Show()
end
