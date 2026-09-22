-- WoW Forever Guild Mute: speech bubbles.
--
-- Hiding a say, yell or party line in chat leaves its speech bubble over the player's head. The
-- game draws that bubble itself a moment after the chat event, so the bubble is looked for over
-- the next few frames and made invisible (alpha 0) when its text is the hidden line. Bubbles are
-- recycled for later lines, so one that shows different text is made visible again. Bubbles in
-- instances are protected; C_ChatBubbles.GetAllChatBubbles(false) leaves them out and they stay.

local _, ns = ...

local next, pairs, type = next, pairs, type

local BUBBLE_EVENTS = {
    CHAT_MSG_SAY = true,
    CHAT_MSG_YELL = true,
    CHAT_MSG_PARTY = true,
    CHAT_MSG_PARTY_LEADER = true,
}
local WATCH_SECONDS = 1 -- how long after a hidden line its bubble is looked for
local TICK = 0.2 -- the scan only runs while a hidden line's bubble is awaited or hidden

local wanted = {} -- [line text] = GetTime() until which a bubble showing it is hidden
local hidden = {} -- [bubble text frame] = the text it was hidden for
local seen = {} -- reused by every scan
local ticking = false

local function Readable(value)
    return not canaccessvalue or canaccessvalue(value)
end

-- The frame inside a bubble that holds its text (ChatBubbleTemplate, with a String font string).
local function TextFrame(bubble)
    local frame = bubble.GetChildren and bubble:GetChildren()
    if frame and frame.String and not (frame.IsForbidden and frame:IsForbidden()) then
        return frame
    end
end

local function Scan()
    local now = GetTime()
    for text, untilTime in pairs(wanted) do
        if now > untilTime then
            wanted[text] = nil
        end
    end
    for frame in pairs(seen) do
        seen[frame] = nil
    end
    for _, bubble in pairs(C_ChatBubbles.GetAllChatBubbles(false)) do
        local frame = TextFrame(bubble)
        if frame then
            seen[frame] = true
            local text = frame.String:GetText()
            if Readable(text) then
                if hidden[frame] and hidden[frame] ~= text then
                    frame:SetAlpha(1) -- recycled for someone else's line
                    hidden[frame] = nil
                end
                if type(text) == "string" and wanted[text] then
                    frame:SetAlpha(0)
                    hidden[frame] = text
                end
            end
        end
    end
    -- A bubble the game no longer lists is gone; forget it but leave it visible for reuse.
    for frame in pairs(hidden) do
        if not seen[frame] then
            frame:SetAlpha(1)
            hidden[frame] = nil
        end
    end
    return next(wanted) ~= nil or next(hidden) ~= nil
end

local function Tick()
    if Scan() then
        C_Timer.After(TICK, Tick)
    else
        ticking = false
    end
end

-- Called by the chat filter for each line it hides.
function ns.HideBubble(event, text)
    if not BUBBLE_EVENTS[event] or type(text) ~= "string" or not (C_ChatBubbles and C_ChatBubbles.GetAllChatBubbles) then
        return
    end
    wanted[text] = GetTime() + WATCH_SECONDS
    if not ticking then
        ticking = true
        C_Timer.After(0, Tick)
    end
end
