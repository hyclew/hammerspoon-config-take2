local module = {
--[=[
    _NAME        = 'clipboard manager',
    _VERSION     = 'the 1st digit of Pi/0',
    _URL         = 'https://github.com/asmagill/hammerspoon-config',
    _LICENSE     = [[ See README.md ]]
    _DESCRIPTION = [[

          This is a rewrite of code originally found at:
            https://github.com/victorso/.hammerspoon/blob/master/tools/clipboard.lua

          In attempting to modify/extend it, I broke it, so I'm starting over, but much
          of this code will be influenced by the original with additions to take advantage
          of new features in Hammerspoon.

    ]],
    _TODOLIST    = [[

          [X] duplicate detection
          [X] right-click for settings
          [X]     change history size?
          [X]     adjust polling rate?
          [X]     toggle paste on select
          [X]     clear
          [X] make sure label truncation doesn't break UTF8 character

          [ ] multiple clip histories?  swap in and out?
          [ ]   add to alternate for clipping sets?
          [ ]   clipping sets should allow labels other than content

          [ ] image support

    ]]
--]=]
}

local utf8     = require("hs.utf8")
local settings = require("hs.settings")
local pb       = require("hs.pasteboard")
local timer    = require("hs.timer")
-- local menubar  = require("hs.menubar")
local menubar  = require("hs._asm.guitk.menubar")
local eventtap = require("hs.eventtap")
local stext    = require("hs.styledtext")

local hashFN   = require("hs.hash").MD5 -- can use other hash fn if this proves insufficient
local prompt   = require("utils.prompter").prompt

local settingsTag = "_asm.newClipper"
-- local menuTitle   = utf8.codepointToUTF8("U+1f4cb") -- clipboard
local menuTitle   = utf8.codepointToUTF8("U+1f4ce") -- paperclip

-- private variables and methods -----------------------------------------

local getSetting = function(label, default) return settings.get(settingsTag.."."..label) or default end
local setSetting = function(label, value)   return settings.set(settingsTag.."."..label, value) end

local maxSize         = getSetting("maxSize", 128 * 1024)    -- if larger than 128KB, don't bother saving
local frequency       = getSetting("frequency", 1)           -- poll frequency
local historySize     = getSetting("historySize", 25)        -- how many items to remember
local labelLength     = getSetting("labelLength", 30)        -- truncate text greater than this in menu
local typeOnSelect    = getSetting("typeOnSelect", false)    -- type selection rather than update clipboard
local typeAlsoUpdates = getSetting("typeAlsoUpdates", false) -- ok, also update clipboard
local autoSave        = getSetting("autoSave", false)        -- save on changes to history

local ignoredIdentifiers = {      -- See http://nspasteboard.org
    ["de.petermaurer.TransientPasteboardType"] = true, -- Transient : Textpander, TextExpander, Butler
    ["com.typeit4me.clipping"]                 = true, -- Transient : TypeIt4Me
    ["Pasteboard generator type"]              = true, -- Transient : Typinator
    ["com.agilebits.onepassword"]              = true, -- Confidential : 1Password
    ["org.nspasteboard.TransientType"]         = true, -- Universal, Transient
    ["org.nspasteboard.ConcealedType"]         = true, -- Universal, Concealed
    ["org.nspasteboard.AutoGeneratedType"]     = true, -- Universal, Automatic
}

local prepareInitialHistory = function(rawHistory)
    local results = { hashed = {}, history = {} }
    for i,v in ipairs(rawHistory) do
        local key = hashFN(v)
        if not results.hashed[key] then
            table.insert(results.history, v)
            results.hashed[key] = #results.history
        end
    end
    return results
end

local primaryClipHistory = prepareInitialHistory(getSetting("clipHistory", {}))

local saveHistoryAndSettings = function(theHistory)
    setSetting("maxSize",         maxSize)
    setSetting("frequency",       frequency)
    setSetting("historySize",     historySize)
    setSetting("labelLength",     labelLength)
    setSetting("typeOnSelect",    typeOnSelect)
    setSetting("typeAlsoUpdates", typeAlsoUpdates)
    setSetting("autoSave",        autoSave)

    if theHistory then
        setSetting("clipHistory",     theHistory.history)
    end
end

local clearHistory = function(theHistory)
    theHistory = { hashed = {}, history = {} }
    if autoSave then saveHistoryAndSettings(theHistory) end
    return theHistory
end

local shouldRecordContents = function()
    local goAhead = true
    for i,v in ipairs(pb.pasteboardTypes()) do
        if ignoredIdentifiers[v] then
            goAhead = false
            break
        end
    end
    if goAhead then
        for i,v in ipairs(pb.contentTypes()) do
            if ignoredIdentifiers[v] then
                goAhead = false
                break
            end
        end
    end
    return goAhead
end

local addToHistory = function(theClipping, theHistory)
    if shouldRecordContents() and theClipping then
        local hashValue = hashFN(theClipping)
        table.insert(theHistory.history, theClipping)

        if theHistory.hashed[hashValue] then
            table.remove(theHistory.history, theHistory.hashed[hashValue])
        else
            local overage = #theHistory.history - historySize
            while (overage > 0) do
                theHistory.hashed[hashFN(theHistory.history[1])] = nil
                table.remove(theHistory.history, 1)
                for k, v in pairs(theHistory.hashed) do theHistory.hashed[k] = theHistory.hashed[k] - 1 end
                overage = #theHistory.history - historySize
            end
        end
        theHistory.hashed[hashValue] = #theHistory.history
        if autoSave then saveHistoryAndSettings(theHistory) end
    end
end

local removeFromHistory = function(index, theHistory)
    table.remove(theHistory.history, index)
    local historyHolder = prepareInitialHistory(theHistory.history)
    theHistory.history = historyHolder.history
    theHistory.hashed  = historyHolder.hashed
    if autoSave then saveHistoryAndSettings(theHistory) end
end

local itemSelected = function(index, theHistory)
    local done = false
    local mods = eventtap.checkKeyboardModifiers()
    if mods.ctrl then
        removeFromHistory(index, theHistory)
        done = true
    elseif typeOnSelect or mods.alt then
        eventtap.keyStrokes(theHistory.history[index])
        done = not typeAlsoUpdates
    end
    if not done then
        pb.setContents(theHistory.history[index])
        lastChangeCount = pb.changeCount()
    end
end

local renderNewClipperMenu = function(mods)
    local results = {}
    if not eventtap.checkMouseButtons().right then

-- do regular menu

        if #primaryClipHistory.history == 0 then
            table.insert(results, { title = "empty", disabled = true })
        else

            table.insert(results, { title = stext.new("Hold down "..utf8.registeredKeys.alt.." to "
                          ..utf8.registeredKeys.leftDoubleQuote.."type"
                          ..utf8.registeredKeys.rightDoubleQuote..
                          " selection immediately", {
--                                 font = stext.convertFont(stext.defaultFonts.menu, stext.fontTraits.italicFont),
-- convert functions apparently haven't caught up with Big Sur because italicizing the default
-- menu font gives ".SFNS-RegularItalic" which is now reported as "unknown". This seems to work
-- for now, but will need to see if there is a new "preferred" way to "convert" fonts.
                                font = { name = stext.defaultFonts.menu.name .. "Italic", size = stext.defaultFonts.menu.size },
                                color = { list="x11", name="royalblue"},
                          }), disabled = true
                      })
            table.insert(results, { title = stext.new("Hold down "..utf8.registeredKeys.ctrl.." to remove selection from history", {
--                                 font = stext.convertFont(stext.defaultFonts.menu, stext.fontTraits.italicFont),
-- convert functions apparently haven't caught up with Big Sur because italicizing the default
-- menu font gives ".SFNS-RegularItalic" which is now reported as "unknown". This seems to work
-- for now, but will need to see if there is a new "preferred" way to "convert" fonts.
                                font = { name = stext.defaultFonts.menu.name .. "Italic", size = stext.defaultFonts.menu.size },
                                color = { list="x11", name="royalblue"},
                          }), disabled = true
                      })
            table.insert(results, { title = "-" })

            for i = #primaryClipHistory.history, 1, -1 do
                local itemTitle = (#primaryClipHistory.history[i] > labelLength) and
                      primaryClipHistory.history[i]:sub(1, labelLength).." "..utf8.codepointToUTF8("U+2026") or
                      primaryClipHistory.history[i]
                table.insert(results, {
                    title = itemTitle,
                    fn = function() itemSelected(i, primaryClipHistory) end
                })
            end
        end

    else

-- do special menu
        table.insert(results, { title = stext.new("newClipper Options", {
--                             font = stext.convertFont(stext.defaultFonts.menu, stext.fontTraits.italicFont),
-- convert functions apparently haven't caught up with Big Sur because italicizing the default
-- menu font gives ".SFNS-RegularItalic" which is now reported as "unknown". This seems to work
-- for now, but will need to see if there is a new "preferred" way to "convert" fonts.
                            font = { name = stext.defaultFonts.menu.name .. "Italic", size = stext.defaultFonts.menu.size },
                            color = { list="x11", name="royalblue"},
                      }), disabled = true
                  })
        table.insert(results, { title = "-" })

        table.insert(results, { title = "Maximum item size: "..tostring(maxSize).." byte(s)",
                                fn = function()
                                    prompt("Maximum clipboard item size to save in history in bytes:",
                                        maxSize,
                                        function(input)
                                            if input then
                                                if tonumber(input) then
                                                    maxSize = tonumber(input)
                                                    saveHistoryAndSettings(nil)
                                                end
                                            end
                                        end)
                                end })
        table.insert(results, { title = "Polling frequency: "..tostring(frequency).." second(s)",
                                fn = function()
                                    prompt("Clipboard polling frquency in seconds:",
                                        frequency,
                                        function(input)
                                            if input then
                                                if tonumber(input) then
                                                    frequency = tonumber(input)
                                                    saveHistoryAndSettings(nil)
                                                end
                                            end
                                        end)
                                end })
        table.insert(results, { title = "Maximum items saved: "..tostring(historySize),
                                fn = function()
                                    prompt("Maximum number of items to save in history:",
                                        historySize,
                                        function(input)
                                            if input then
                                                if tonumber(input) then
                                                    historySize = tonumber(input)
                                                    saveHistoryAndSettings(nil)
                                                end
                                            end
                                        end)
                                end })
        table.insert(results, { title = "Maximum label length: "..tostring(labelLength),
                                fn = function()
                                    prompt("Maximum number of characters to display for each item:",
                                        labelLength,
                                        function(input)
                                            if input then
                                                if tonumber(input) then
                                                    labelLength = tonumber(input)
                                                    saveHistoryAndSettings(nil)
                                                end
                                            end
                                        end)
                                end })

        table.insert(results, { title = "-" })

        table.insert(results, { title = "Auto-save history", checked = autoSave,
                                fn = function()
                                    autoSave = not autoSave
                                    saveHistoryAndSettings(nil)
                                end })
        table.insert(results, { title = "Type selection instead of updating clipboard", checked = typeOnSelect,
                                fn = function()
                                    typeOnSelect = not typeOnSelect
                                    saveHistoryAndSettings(nil)
                                end })
        table.insert(results, { title = "Also update clipboard when typing", checked = typeAlsoUpdates,
                                fn = function()
                                    typeAlsoUpdates = not typeAlsoUpdates
                                    saveHistoryAndSettings(nil)
                                end })
        table.insert(results, { title = "-" })
        table.insert(results, { title = "Clear history",
                                fn = function() primaryClipHistory = clearHistory(primaryClipHistory) end })
        table.insert(results, { title = "Save history now",
                                fn = function() saveHistoryAndSettings(primaryClipHistory) end })
    end

    table.insert(results, { title = "-" })
    table.insert(results, { title = stext.new("newClipper for Hammerspoon", {
--                                 font = stext.convertFont(stext.defaultFonts.menu, stext.fontTraits.italicFont),
-- convert functions apparently haven't caught up with Big Sur because italicizing the default
-- menu font gives ".SFNS-RegularItalic" which is now reported as "unknown". This seems to work
-- for now, but will need to see if there is a new "preferred" way to "convert" fonts.
                                font = { name = stext.defaultFonts.menu.name .. "Italic", size = stext.defaultFonts.menu.size },
                                color = { list="x11", name="royalblue"},
                                paragraphStyle = { alignment = "right" },
                              }), disabled = true
                          })
    return results
end

local lastChangeCount = pb.changeCount()

-- Public interface ------------------------------------------------------

module.clipWatcher = timer.new(frequency, function()
    local currentChangeCount = pb.changeCount()
    if lastChangeCount ~= currentChangeCount then
        for i, v in ipairs(pb.contentTypes()) do
            if v == "public.utf8-plain-text" then
                local clipping = pb.getContents()
                addToHistory(clipping, primaryClipHistory)
                break
            end
        end
        lastChangeCount = currentChangeCount
    end
end):start()

module.menu = menubar.new():setTitle(menuTitle):setMenu(renderNewClipperMenu)

-- Return Module Object --------------------------------------------------

return module
