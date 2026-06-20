local logger = require("logger")
logger.info("Applying custom UI fonts patch")

local ReaderFont = require("apps/reader/modules/readerfont")
local Font = require("ui/font")
local FontList = require("fontlist")
local UIManager = require("ui/uimanager")
local BD = require("ui/bidi")
local T = require("ffi/util").template
local _ = require("gettext")
local util = require("util")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local DictQuickLookup = require("ui/widget/dictquicklookup")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local ReaderMenu = require("apps/reader/modules/readermenu")
local userpatch = require("userpatch")

local INHERITED_MENU_PREFIX = "\u{2592}\u{200A}"

local function showUIFontRestartPrompt()
	UIManager:show(ConfirmBox:new({
		text = _("Font changed. You need to restart KOReader to apply the changes."),
		ok_text = _("Restart"),
		ok_callback = function()
			UIManager:nextTick(function()
				os.execute("sleep 1")
				UIManager:restartKOReader()
			end)
		end,
		cancel_text = _("Later"),
	}))
end

local function returnToParentMenu(touchmenu_instance)
	if touchmenu_instance and touchmenu_instance.backToUpperMenu then
		touchmenu_instance:backToUpperMenu(true)
	end
end

local function deferUIFontAction(action, after_action)
	UIManager:scheduleIn(0.1, function()
		action()
		if after_action then
			after_action()
		end
	end)
end

local function deferUIFontChange(action)
	deferUIFontAction(action, function()
		showUIFontRestartPrompt()
	end)
end

--------------------------------------------------------------------------------
-- 1. SHARED LOGIC
--------------------------------------------------------------------------------

local function getGenericFontTable(reader_font_instance, options)
	local fonts_table = {}
	local cre = require("document/credocument"):engineInit()
	local fonts = cre.getFontFaces()

	fonts = reader_font_instance.sortFaceList and reader_font_instance:sortFaceList(fonts) or fonts

	for i, font_name in ipairs(fonts) do
		local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(font_name)
		if not font_filename then
			font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(font_name, nil, true)
		end
		local display_name = font_name
		if font_filename and font_faceindex then
			display_name = FontList:getLocalizedFontName(font_filename, font_faceindex) or display_name
		end

		table.insert(fonts_table, {
			text = display_name,
			enabled_func = function()
				return not options.mark_active_func(font_filename, font_name)
			end,
			keep_menu_open = options.keep_menu_open_on_change == true
				or options.return_to_parent_on_change == true
				or options.close_to_parent_on_change == true,
			font_func = function(size)
				if font_filename then
					return Font:getFace(font_filename, size)
				end
			end,
			callback = function(touchmenu_instance)
				local val_to_save = options.save_path_as_name and font_name or font_filename
				local function saveSelection()
					G_reader_settings:saveSetting(options.setting_key_path, val_to_save)
					if options.setting_key_name then
						G_reader_settings:saveSetting(options.setting_key_name, font_name)
					end
				end
				if val_to_save then
					if options.on_select_func then
						options.on_select_func(touchmenu_instance, font_filename, font_name)
					elseif options.restart_on_change then
						if options.return_to_parent_on_change or options.close_to_parent_on_change then
							deferUIFontAction(saveSelection, function()
								returnToParentMenu(touchmenu_instance)
								showUIFontRestartPrompt()
							end)
						else
							saveSelection()
							showUIFontRestartPrompt()
						end
					else
						if options.return_to_parent_on_change then
							deferUIFontAction(function()
								saveSelection()
								UIManager:setDirty(nil, "ui")
							end, function()
								returnToParentMenu(touchmenu_instance)
							end)
						else
							saveSelection()
							UIManager:setDirty(nil, "ui")
							if touchmenu_instance then
								touchmenu_instance:updateItems()
							end
						end
					end
				else
					UIManager:show(InfoMessage:new({ text = _("Could not determine filename for this font.") }))
				end
			end,
		})
	end
	return fonts_table
end

local function getScopedFontSettingKeys(prefix, suffix)
	return {
		path = prefix .. "_" .. suffix .. "_path",
		name = prefix .. "_" .. suffix .. "_name",
	}
end

local function saveFontOverride(setting_keys, font_path, font_name)
	if font_path then
		G_reader_settings:saveSetting(setting_keys.path, font_path)
	else
		G_reader_settings:delSetting(setting_keys.path)
	end

	if font_name then
		G_reader_settings:saveSetting(setting_keys.name, font_name)
	else
		G_reader_settings:delSetting(setting_keys.name)
	end
end

--------------------------------------------------------------------------------
-- 2. UI FONT LOGIC
--------------------------------------------------------------------------------

local function flattenGroupOptions(groups)
	local options = {}
	for _, group in ipairs(groups) do
		for _, option in ipairs(group.options) do
			table.insert(options, option)
		end
	end
	return options
end

local UI_FONT_OPTIONS = {
	cfont = { fontmap_key = "cfont", label = _("Menu contents"), variant = "regular" },
	tfont = { fontmap_key = "tfont", label = _("Title"), variant = "bold" },
	smalltfont = { fontmap_key = "smalltfont", label = _("Small title"), variant = "bold" },
	x_smalltfont = { fontmap_key = "x_smalltfont", label = _("Extra small title"), variant = "bold" },
	scfont = { fontmap_key = "scfont", label = _("Item shortcut"), variant = "regular" },
	ffont = { fontmap_key = "ffont", label = _("Footer"), variant = "regular" },
	smallffont = { fontmap_key = "smallffont", label = _("Small footer"), variant = "regular" },
	largeffont = { fontmap_key = "largeffont", label = _("Large footer"), variant = "regular" },
	rifont = { fontmap_key = "rifont", label = _("Reading position info"), variant = "regular" },
	pgfont = { fontmap_key = "pgfont", label = _("Pagination display"), variant = "regular" },
	hpkfont = { fontmap_key = "hpkfont", label = _("Help keys"), variant = "regular" },
	hfont = { fontmap_key = "hfont", label = _("Help text"), variant = "regular" },
	infont = { fontmap_key = "infont", label = _("Input/Keyboard"), variant = "regular" },
	smallinfont = { fontmap_key = "smallinfont", label = _("Code - Monospace"), variant = "regular" },
	infofont = { fontmap_key = "infofont", label = _("Info message"), variant = "regular" },
	smallinfofont = { fontmap_key = "smallinfofont", label = _("Small info message"), variant = "regular" },
	smallinfofontbold = { fontmap_key = "smallinfofontbold", label = _("Small bold info message"), variant = "bold" },
	x_smallinfofont = { fontmap_key = "x_smallinfofont", label = _("Extra small info message"), variant = "regular" },
	xx_smallinfofont = { fontmap_key = "xx_smallinfofont", label = _("Extra extra small info message"), variant = "regular" },
}

local UI_FONT_GROUP_MENUS_AND_TITLES = {
	label = _("Menus and Titles"),
	options = {
		UI_FONT_OPTIONS.cfont,
		UI_FONT_OPTIONS.tfont,
		UI_FONT_OPTIONS.smalltfont,
		UI_FONT_OPTIONS.x_smalltfont,
		UI_FONT_OPTIONS.scfont,
	},
}

local UI_FONT_GROUP_FOOTER_AND_STATUS = {
	label = _("Footer and Status"),
	options = {
		UI_FONT_OPTIONS.ffont,
		UI_FONT_OPTIONS.smallffont,
		UI_FONT_OPTIONS.largeffont,
		UI_FONT_OPTIONS.rifont,
		UI_FONT_OPTIONS.pgfont,
	},
}

local UI_FONT_GROUP_HELP_AND_INPUT = {
	label = _("Help and Input"),
	options = {
		UI_FONT_OPTIONS.hpkfont,
		UI_FONT_OPTIONS.hfont,
		UI_FONT_OPTIONS.infont,
		UI_FONT_OPTIONS.smallinfont,
	},
}

local UI_FONT_GROUP_INFO_MESSAGES = {
	label = _("Info Messages"),
	options = {
		UI_FONT_OPTIONS.infofont,
		UI_FONT_OPTIONS.smallinfofont,
		UI_FONT_OPTIONS.smallinfofontbold,
		UI_FONT_OPTIONS.x_smallinfofont,
		UI_FONT_OPTIONS.xx_smallinfofont,
	},
}

local UI_FONT_GROUP_LIST = {
	UI_FONT_GROUP_MENUS_AND_TITLES,
	UI_FONT_GROUP_FOOTER_AND_STATUS,
	UI_FONT_GROUP_HELP_AND_INPUT,
	UI_FONT_GROUP_INFO_MESSAGES,
}

local UI_FONT_OPTION_LIST = flattenGroupOptions(UI_FONT_GROUP_LIST)

local function getUIFontSettingKeys(fontmap_key)
	return getScopedFontSettingKeys("uifont", fontmap_key)
end

local function getRegularFontPath(font_path)
	if not font_path then
		return nil
	end

	for regular_path, bold_path in pairs(Font.bold_font_variant) do
		if bold_path == font_path then
			return regular_path
		end
	end

	return font_path
end

local function getFontDisplayName(font_path, cached_name)
	if cached_name then
		return cached_name
	end

	if not font_path then
		return _("Default")
	end

	local lookup_path = getRegularFontPath(font_path)
	local cre = require("document/credocument"):engineInit()
	for _, font_name in ipairs(cre.getFontFaces()) do
		local resolved_path, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(font_name)
		if not resolved_path then
			resolved_path, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(font_name, nil, true)
		end
		if resolved_path == lookup_path then
			return FontList:getLocalizedFontName(resolved_path, font_faceindex) or font_name
		end
	end

	local path_dummy, file = util.splitFilePathName(font_path)
	return file or _("Custom")
end

local function getDefaultUIFontPath()
	return G_reader_settings:readSetting("uifont_path") or getRegularFontPath(Font.fontmap.cfont)
end

local function makeRefreshableItemTable(item_table, refresh_func)
	item_table.needs_refresh = true
	item_table.refresh_func = refresh_func
	return item_table
end

local function hasUIFontOverride(option)
	local setting_keys = getUIFontSettingKeys(option.fontmap_key)
	return G_reader_settings:readSetting(setting_keys.path) ~= nil
end

local function saveUIFontOptionOverride(option, font_path, font_name)
	saveFontOverride(getUIFontSettingKeys(option.fontmap_key), font_path, font_name)
end

local function clearUIFontOptionOverride(option)
	saveUIFontOptionOverride(option, nil, nil)
end

local function clearUIFontOverrides(options)
	for _, option in ipairs(options) do
		clearUIFontOptionOverride(option)
	end
end

local function setUIFontOverrides(options, font_path, font_name)
	for _, option in ipairs(options) do
		saveUIFontOptionOverride(option, font_path, font_name)
	end
end

local function getUIFontNameDisplay(font_path, cached_name, inherited)
	local display_name = getFontDisplayName(font_path, cached_name)
	if inherited then
		return INHERITED_MENU_PREFIX .. display_name
	end
	return display_name
end

local function getUIFontBasePath(option)
	local setting_keys = getUIFontSettingKeys(option.fontmap_key)
	return G_reader_settings:readSetting(setting_keys.path)
		or G_reader_settings:readSetting("uifont_path")
		or getRegularFontPath(Font.fontmap[option.fontmap_key])
end

local function getUIFontGroupSharedBasePath(group)
	local shared_path = nil
	for _, option in ipairs(group.options) do
		local option_path = getUIFontBasePath(option)
		if shared_path == nil then
			shared_path = option_path
		elseif shared_path ~= option_path then
			return nil
		end
	end
	return shared_path
end

local function getUIFontTargetPath(option)
	local font_path = getUIFontBasePath(option)
	if not font_path then
		return nil
	end

	if option.variant == "bold" then
		return Font.bold_font_variant[font_path] or font_path
	end

	return font_path
end

local function applyUIFont()
	for _, option in ipairs(UI_FONT_OPTION_LIST) do
		local target_path = getUIFontTargetPath(option)
		if target_path then
			Font.fontmap[option.fontmap_key] = target_path
		end
	end
end

applyUIFont()

--------------------------------------------------------------------------------
-- FONT OVERRIDE CLASS (Unified logic for main menu, dictionary, and titlebar font overrides)
--------------------------------------------------------------------------------

local FontOverride = {
	SETTINGS_KEY = "",
	FONT_PATH_SETTING ="",
	FONT_NAME_SETTING = "",
	FONT_OPTIONS = {
		{
			setting_suffix = "",
			label = _(""),
			default_face_name = "",
		},
	},
}

function FontOverride:new (o)
	o = o or {}   -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self
	return o
end

function FontOverride:getFontOption(option_key)
	if not option_key then
		return nil
	end

	local option = self.FONT_OPTIONS and self.FONT_OPTIONS[option_key]
	if option then
		return option
	end

	if type(option_key) == "string" and self.FONT_OPTIONS then
		for _, candidate in pairs(self.FONT_OPTIONS) do
			if candidate.setting_suffix == option_key then
				return candidate
			end
		end
	end

	return nil
end

function FontOverride:getFontSettingKeys(option_key)
	local option = self:getFontOption(option_key)
	local setting_suffix = option and option.setting_suffix or option_key
	return getScopedFontSettingKeys(self.SETTINGS_KEY, setting_suffix)
end

function FontOverride:getFontOverridePath()
	return G_reader_settings:readSetting(self.FONT_PATH_SETTING)
end

function FontOverride:hasFontOverride()
	return self:getFontOverridePath() ~= nil
end

function FontOverride:getFontBasePath()
	return self:getFontOverridePath() or getRegularFontPath(Font.fontmap.smallinfofont)
end

function FontOverride:getDefaultFontPath(option_key)
	local option = self:getFontOption(option_key)
	return option and getRegularFontPath(Font.fontmap[option.default_face_name]) or nil
end

function FontOverride:hasFontSlotOverride(option_key)
	local setting_keys = self:getFontSettingKeys(option_key)
	return G_reader_settings:readSetting(setting_keys.path) ~= nil
end

function FontOverride:getFontPath(option_key)
	local setting_keys = self:getFontSettingKeys(option_key)
	return G_reader_settings:readSetting(setting_keys.path)
		or self:getFontOverridePath()
		or self:getDefaultFontPath(option_key)
end

function FontOverride:saveFontSlotOverride(option_key, font_path, font_name)
	saveFontOverride(self:getFontSettingKeys(option_key), font_path, font_name)
end

function FontOverride:clearFontSlotOverride(option_key)
	self:saveFontSlotOverride(option_key, nil, nil)
end

function FontOverride:clearFontSlotOverrides(option_keys)
	for _, option in ipairs(option_keys) do
		self:clearFontSlotOverride(option)
	end
	UIManager:setDirty(nil, "ui")
end

function FontOverride:getOptionKeyList()
	local keys = {}
	for _, option in pairs(self.FONT_OPTIONS) do
		table.insert(keys, option.setting_suffix)
	end
	return keys
end

function FontOverride:getOptionList()
	if self.FONT_OPTION_LIST then
		return self.FONT_OPTION_LIST
	end

	local options = {}
	for _, option in pairs(self.FONT_OPTIONS) do
		table.insert(options, option)
	end
	table.sort(options, function(a, b)
		return a.setting_suffix < b.setting_suffix
	end)
	return options
end

function FontOverride:getInheritedFontPath(option_key)
	if self:hasFontOverride() then
		return self:getFontBasePath(), G_reader_settings:readSetting(self.FONT_NAME_SETTING), true
	end
	return self:getDefaultFontPath(option_key), nil, false
end

function FontOverride:getFontDisplay(option_key)
	local setting_keys = self:getFontSettingKeys(option_key)
	local has_override = self:hasFontSlotOverride(option_key)
	if has_override then
		return getUIFontNameDisplay(self:getFontPath(option_key), G_reader_settings:readSetting(setting_keys.name), false)
	end

	local inherited_path, inherited_name = self:getInheritedFontPath(option_key)
	return getUIFontNameDisplay(inherited_path, inherited_name, true)
end

function FontOverride:getFace(option_key, font_size)
	
	local font_path = self:getFontPath(option_key)
	local option = self:getFontOption(option_key)
	local default_face = option and Font:getFace(option.default_face_name)
	if not default_face then
		return font_path and Font:getFace(font_path, font_size) or nil
	end
	local font_size = font_size or default_face.orig_size
	if font_path then
		return Font:getFace(font_path, font_size)
	end
	return default_face
end

--------------------------------------------------------------------------------
-- MAIN MENU FONT LOGIC
--------------------------------------------------------------------------------

local TouchMenu = require("ui/widget/touchmenu")
local original_TouchMenu_init, original_TouchMenu_updateItems

local MAIN_MENU_FONT_KEY = "mainmenu"
local MAIN_MENU_FONT_PATH_SETTING = "mainmenu_font_path"
local MAIN_MENU_FONT_NAME_SETTING = "mainmenu_font_name"
local MAIN_MENU_FONT_OPTIONS = {
	menu_item = {
		setting_suffix = "menu_item",
		label = _("Menu items"),
		default_face_name = "smallinfofont",
	},
	page_info_text = {
		setting_suffix = "page_info_text",
		label = _("Page info text"),
		default_face_name = "ffont",
	},
	time_info = {
		setting_suffix = "time_info",
		label = _("Time and battery info"),
		default_face_name = "ffont",
	},
}
local MAIN_MENU_FONT_OPTION_LIST = {
	MAIN_MENU_FONT_OPTIONS.menu_item,
	MAIN_MENU_FONT_OPTIONS.page_info_text,
	MAIN_MENU_FONT_OPTIONS.time_info,
}

local MainMenuFontOverrides = FontOverride:new{
	SETTINGS_KEY = MAIN_MENU_FONT_KEY,
	FONT_PATH_SETTING = MAIN_MENU_FONT_PATH_SETTING,
	FONT_NAME_SETTING = MAIN_MENU_FONT_NAME_SETTING,
	FONT_OPTIONS = MAIN_MENU_FONT_OPTIONS,
	FONT_OPTION_LIST = MAIN_MENU_FONT_OPTION_LIST,
}

local cached_touchmenu_item_class = nil
local touchmenu_item_class_lookup_attempted = false

local function getTouchMenuItemClass()
	if touchmenu_item_class_lookup_attempted then
		return cached_touchmenu_item_class
	end

	touchmenu_item_class_lookup_attempted = true
	if not debug or not debug.getupvalue then
		logger.warn("Ultimate Fonts: debug.getupvalue unavailable, main menu item font override limited to footer text")
		return nil
	end

	local update_items_func = original_TouchMenu_updateItems or TouchMenu.updateItems
	if not update_items_func then
		logger.warn("Ultimate Fonts: TouchMenu.updateItems unavailable, main menu item font override limited to footer text")
		return nil
	end

	for index = 1, 20 do
		local name, value = debug.getupvalue(update_items_func, index)
		if not name then
			break
		end
		if name == "TouchMenuItem" and type(value) == "table" then
			cached_touchmenu_item_class = value
			break
		end
	end

	if not cached_touchmenu_item_class then
		logger.warn("Ultimate Fonts: could not resolve TouchMenuItem upvalue, main menu item font override limited to footer text")
	end

	return cached_touchmenu_item_class
end

local function applyMainMenuFontToTouchMenu(touchmenu)
	local touchmenu_item_class = getTouchMenuItemClass()
	if touchmenu_item_class then
		touchmenu_item_class.face = MainMenuFontOverrides:getFace(MainMenuFontOverrides.FONT_OPTIONS.menu_item.setting_suffix)
	end

	touchmenu.fface = MainMenuFontOverrides:getFace(MainMenuFontOverrides.FONT_OPTIONS.page_info_text.setting_suffix)
	if touchmenu.page_info_text then
		touchmenu.page_info_text.face = MainMenuFontOverrides:getFace(MainMenuFontOverrides.FONT_OPTIONS.page_info_text.setting_suffix)
	end
	if touchmenu.time_info then
		touchmenu.time_info.face = MainMenuFontOverrides:getFace(MainMenuFontOverrides.FONT_OPTIONS.time_info.setting_suffix)
	end
	if touchmenu.device_info then
		touchmenu.device_info:resetLayout()
	end
	if touchmenu.page_info then
		touchmenu.page_info:resetLayout()
	end
end

original_TouchMenu_init = TouchMenu.init
---@diagnostic disable-next-line: duplicate-set-field
function TouchMenu:init(...)
	applyMainMenuFontToTouchMenu(self)
	return original_TouchMenu_init(self, ...)
end

original_TouchMenu_updateItems = TouchMenu.updateItems
---@diagnostic disable-next-line: duplicate-set-field
function TouchMenu:updateItems(...)
	applyMainMenuFontToTouchMenu(self)
	return original_TouchMenu_updateItems(self, ...)
end

--------------------------------------------------------------------------------
-- DICTIONARY FONT LOGIC
--------------------------------------------------------------------------------

local DICT_FONT_KEY = "dictquicklookup"
local DICT_FONT_PATH_SETTING = "dictquicklookup_font_path"
local DICT_FONT_NAME_SETTING = "dictquicklookup_font_name"

local DICT_FONT_OPTIONS = {
	content_face = {
		setting_suffix = "content_face",
		label = _("Content Font"),
		default_face_name = "cfont",
	},
	image_alt_face  = {
		setting_suffix = "image_alt_face",
		label = _("Image Alt Font"),
		default_face_name = "cfont",
	},
	word_font_face  = {
		setting_suffix = "word_font_face",
		label = _("Lookup Word Font"),
		default_face_name = "tfont",
	},
}

local DictQuickLookupOverrides = FontOverride:new{
	SETTINGS_KEY = DICT_FONT_KEY,
	FONT_PATH_SETTING = DICT_FONT_PATH_SETTING,
	FONT_NAME_SETTING = DICT_FONT_NAME_SETTING,
	FONT_OPTIONS = DICT_FONT_OPTIONS,
}

local original_DictQuickLookup_init = DictQuickLookup.init

---@diagnostic disable-next-line: duplicate-set-field
function DictQuickLookup:init(...)
	self.dict_font_size = G_reader_settings:readSetting("dict_font_size") or 20
	self.content_face = DictQuickLookupOverrides:getFace(DictQuickLookupOverrides.FONT_OPTIONS.content_face.setting_suffix, self.dict_font_size)
	local font_size_alt = self.dict_font_size - 4
    if font_size_alt < 8 then
        font_size_alt = 8
    end
	self.image_alt_face = DictQuickLookupOverrides:getFace(DictQuickLookupOverrides.FONT_OPTIONS.image_alt_face.setting_suffix, font_size_alt)
	-- self.word_font_face = DictQuickLookupOverrides:getFontPath(DictQuickLookupOverrides.FONT_OPTIONS.word_font_face.setting_suffix)
	
	return original_DictQuickLookup_init(self, ...)
end


-- local original_getHtmlDictionaryCss = DictQuickLookup.getHtmlDictionaryCss

-- function DictQuickLookup:getHtmlDictionaryCss()
-- 	local selected_font = DictQuickLookupOverrides:getFontPath(DictQuickLookupOverrides.FONT_OPTIONS.word_font_face.setting_suffix)

-- 	if selected_font then
-- 		local cre = require("document/credocument"):engineInit()
-- 		local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(selected_font)
-- 		if font_filename then
-- 			local css_justify = G_reader_settings:nilOrTrue("dict_justify") and "text-align: justify;" or ""
-- 			local face_css = "@font-face { font-family: 'DictCustomFont'; src: url('" .. font_filename .. "') }\n"
-- 			local seen = { [font_filename] = true }
-- 			local variants = {
-- 				{ bold = false, italic = true, style = "; font-style: italic" },
-- 				{ bold = true, italic = false, style = "; font-weight: bold" },
-- 				{ bold = true, italic = true, style = "; font-weight: bold; font-style: italic" },
-- 			}
-- 			for _, v in ipairs(variants) do
-- 				local path = cre.getFontFaceFilenameAndFaceIndex(selected_font, v.bold, v.italic)
-- 				if path and not seen[path] then
-- 					seen[path] = true
-- 					face_css = face_css
-- 						.. "@font-face { font-family: 'DictCustomFont'; src: url('"
-- 						.. path
-- 						.. "')"
-- 						.. v.style
-- 						.. " }\n"
-- 				end
-- 			end
-- 			local css = face_css
-- 				.. [[
--                 @page { margin: 0; font-family: 'DictCustomFont'; }
--                 body { margin: 0; line-height: 1.3; font-family: 'DictCustomFont'; ]]
-- 				.. css_justify
-- 				.. [[ }
--                 blockquote, dd { margin: 0 1em; }
--                 ol, ul, menu { margin: 0; padding: 0 1.7em; }
--             ]]
-- 			if self.css then
-- 				return css .. self.css
-- 			end
-- 			return css
-- 		end
-- 	end

-- 	return original_getHtmlDictionaryCss(self)
-- end

--------------------------------------------------------------------------------
-- InfoMessage font logic
--------------------------------------------------------------------------------
local InfoMessageWidget = require("ui/widget/infomessage")
local ConfirmBoxWidget = require("ui/widget/confirmbox")

local INFOMESSAGE_FONT_KEY = "infomessage"
local INFOMESSAGE_FONT_PATH_SETTING = "infomessage_font_path"
local INFOMESSAGE_FONT_NAME_SETTING = "infomessage_font_name"

local INFOMESSAGE_FONT_OPTIONS = {
	text_face = {
		setting_suffix = "text_face",
		label = _("Info Message Text"),
		default_face_name = "infofont",
	},
	text_face_monospace = {
		setting_suffix = "text_face_monospace",
		label = _("Info Message Text (Monospace)"),
		default_face_name = "infont",
	},
	confirmbox_face = {
		setting_suffix = "confirmbox_face",
		label = _("Confirm Box Text"),
		default_face_name = "infofont",
	},
}

local INFOMESSAGE_FONT_OPTIONS_LIST = {
	INFOMESSAGE_FONT_OPTIONS.text_face,
	INFOMESSAGE_FONT_OPTIONS.text_face_monospace,
	INFOMESSAGE_FONT_OPTIONS.confirmbox_face,
}

local InfoMessageOverrides = FontOverride:new{
	SETTINGS_KEY = INFOMESSAGE_FONT_KEY,
	FONT_PATH_SETTING = INFOMESSAGE_FONT_PATH_SETTING,
	FONT_NAME_SETTING = INFOMESSAGE_FONT_NAME_SETTING,
	FONT_OPTIONS = INFOMESSAGE_FONT_OPTIONS,
	FONT_OPTION_LIST = INFOMESSAGE_FONT_OPTIONS_LIST,
}


local original_InfoMessageWidget_init = InfoMessageWidget.init
---@diagnostic disable-next-line: duplicate-set-field
function InfoMessageWidget:init(...)
	if self.monospace_font then
		self.face = InfoMessageOverrides:getFace(InfoMessageOverrides.FONT_OPTIONS.text_face_monospace.setting_suffix)
	else
		self.face = InfoMessageOverrides:getFace(InfoMessageOverrides.FONT_OPTIONS.text_face.setting_suffix)
	end
	return original_InfoMessageWidget_init(self, ...)
end

local original_ConfirmBoxWidget_init = ConfirmBoxWidget.init
---@diagnostic disable-next-line: duplicate-set-field
function ConfirmBoxWidget:init(...)
	self.face = InfoMessageOverrides:getFace(InfoMessageOverrides.FONT_OPTIONS.confirmbox_face.setting_suffix)
	return original_ConfirmBoxWidget_init(self, ...)
end

--------------------------------------------------------------------------------
-- Button font logic
--------------------------------------------------------------------------------
local BUTTON_FONT_KEY = "button"
local BUTTON_FONT_PATH_SETTING = "button_font_path"
local BUTTON_FONT_NAME_SETTING = "button_font_name"

local BUTTON_FONT_OPTIONS = {
	button_face = {
		setting_suffix = "button_face",
		label = _("Button Text"),
		default_face_name = "cfont",
	},
	menu_button_face = {
		setting_suffix = "menu_button_face",
		label = _("Menu Button Text"),
		default_face_name = "smallinfofont",
	},
	button_dialog_title_face = {
		setting_suffix = "button_dialog_title_face",
		label = _("Button Dialog Title"),
		default_face_name = "x_smalltfont",
	},
	button_dialog_info_face = {
		setting_suffix = "button_dialog_info_face",
		label = _("Button Dialog Info Text"),
		default_face_name = "infofont",
	},
	button_progress_face = {
		setting_suffix = "button_progress_face",
		label = _("Progress Button Text"),
		default_face_name = "infofont",
	},
}

local BUTTON_FONT_OPTION_LIST = {
	BUTTON_FONT_OPTIONS.button_face,
	BUTTON_FONT_OPTIONS.menu_button_face,
	BUTTON_FONT_OPTIONS.button_dialog_title_face,
	BUTTON_FONT_OPTIONS.button_dialog_info_face,
	BUTTON_FONT_OPTIONS.button_progress_face,
}

local ButtonOverrides = FontOverride:new{
	SETTINGS_KEY = BUTTON_FONT_KEY,
	FONT_PATH_SETTING = BUTTON_FONT_PATH_SETTING,
	FONT_NAME_SETTING = BUTTON_FONT_NAME_SETTING,
	FONT_OPTIONS = BUTTON_FONT_OPTIONS,
	FONT_OPTION_LIST = BUTTON_FONT_OPTION_LIST,
}

local ButtonWidget = require("ui/widget/button")
local original_ButtonWidget_init = ButtonWidget.init
---@diagnostic disable-next-line: duplicate-set-field
function ButtonWidget:init(...)
	if self.menu_style then
		self.text_font_face = ButtonOverrides:getFontPath(ButtonOverrides.FONT_OPTIONS.menu_button_face.setting_suffix)
	else
		self.text_font_face = ButtonOverrides:getFontPath(ButtonOverrides.FONT_OPTIONS.button_face.setting_suffix)
	end
	return original_ButtonWidget_init(self, ...)
end

local ButtonDialogWidget = require("ui/widget/buttondialog")
local original_ButtonDialogWidget_init = ButtonDialogWidget.init
---@diagnostic disable-next-line: duplicate-set-field
function ButtonDialogWidget:init(...)
	self.title_face  = ButtonOverrides:getFace(ButtonOverrides.FONT_OPTIONS.button_dialog_title_face.setting_suffix)
	self.info_face = ButtonOverrides:getFace(ButtonOverrides.FONT_OPTIONS.button_dialog_info_face.setting_suffix)
	return original_ButtonDialogWidget_init(self, ...)
end

local ButtonProgressWidget = require("ui/widget/buttonprogresswidget")
local original_ButtonProgressWidget_init = ButtonProgressWidget.init
---@diagnostic disable-next-line: duplicate-set-field
function ButtonProgressWidget:init(...)
	self.font_face = ButtonOverrides:getFontPath(ButtonOverrides.FONT_OPTIONS.button_progress_face.setting_suffix)
	return original_ButtonProgressWidget_init(self, ...)
end

--------------------------------------------------------------------------------
-- Input font logic
--------------------------------------------------------------------------------
local INPUT_FONT_KEY = "input"
local INPUT_FONT_PATH_SETTING = "input_font_path"
local INPUT_FONT_NAME_SETTING = "input_font_name"

local INPUT_FONT_OPTIONS = {
	input_dialog_face = {
		setting_suffix = "input_dialog_face",
		label = _("Input Text"),
		default_face_name = "x_smallinfofont",
	},
	input_text_face = {
		setting_suffix = "input_text_face",
		label = _("Input Text"),
		default_face_name = "smallinfofont",
	},
}

local INPUT_FONT_OPTION_LIST = {
	INPUT_FONT_OPTIONS.input_dialog_face,
	INPUT_FONT_OPTIONS.input_text_face,
}

local InputOverrides = FontOverride:new{
	SETTINGS_KEY = INPUT_FONT_KEY,
	FONT_PATH_SETTING = INPUT_FONT_PATH_SETTING,
	FONT_NAME_SETTING = INPUT_FONT_NAME_SETTING,
	FONT_OPTIONS = INPUT_FONT_OPTIONS,
	FONT_OPTION_LIST = INPUT_FONT_OPTION_LIST,
}

local InputDialogWidget = require("ui/widget/inputdialog")
local original_InputDialogWidget_init = InputDialogWidget.init
---@diagnostic disable-next-line: duplicate-set-field
function InputDialogWidget:init(...)
	self.input_face = InputOverrides:getFace(InputOverrides.FONT_OPTIONS.input_dialog_face.setting_suffix)
	return original_InputDialogWidget_init(self, ...)
end

local InputTextWidget = require("ui/widget/inputtext")
local original_InputTextWidget_init = InputTextWidget.init
---@diagnostic disable-next-line: duplicate-set-field
function InputTextWidget:init(...)
	self.input_face = InputOverrides:getFace(InputOverrides.FONT_OPTIONS.input_text_face.setting_suffix)
	return original_InputTextWidget_init(self, ...)
end

--------------------------------------------------------------------------------
-- titlebar font logic
--------------------------------------------------------------------------------
local TitlebarWidget = require("ui/widget/titlebar")
local original_TitlebarWidget_init = TitlebarWidget.init

local TITLEBAR_FONT_KEY = "titlebar"
local TITLEBAR_FONT_PATH_SETTING = "titlebar_font_path"
local TITLEBAR_FONT_NAME_SETTING = "titlebar_font_name"

local TITLEBAR_FONT_OPTIONS = {
	title_face_fullscreen = {
		setting_suffix = "title_face_fullscreen",
		label = _("Title (fullscreen)"),
		default_face_name = "smalltfont",
	},
	title_face_not_fullscreen = {
		setting_suffix = "title_face_not_fullscreen",
		label = _("Title (not fullscreen)"),
		default_face_name = "x_smalltfont",
	},
	subtitle_face = {
		setting_suffix = "subtitle_face",
		label = _("Subtitle"),
		default_face_name = "xx_smallinfofont",
	},
	info_text_face = {
		setting_suffix = "info_text_face",
		label = _("Info Text"),
		default_face_name = "x_smallinfofont",
	},
}

local TitlebarOverrides = FontOverride:new{
	SETTINGS_KEY = TITLEBAR_FONT_KEY,
	FONT_PATH_SETTING = TITLEBAR_FONT_PATH_SETTING,
	FONT_NAME_SETTING = TITLEBAR_FONT_NAME_SETTING,
	FONT_OPTIONS = TITLEBAR_FONT_OPTIONS,
}


---@diagnostic disable-next-line: duplicate-set-field
function TitlebarWidget:init(...)
	self.title_face_fullscreen = TitlebarOverrides:getFace(TitlebarOverrides.FONT_OPTIONS.title_face_fullscreen.setting_suffix)
	self.title_face_not_fullscreen = TitlebarOverrides:getFace(TitlebarOverrides.FONT_OPTIONS.title_face_not_fullscreen.setting_suffix)
	self.subtitle_face = TitlebarOverrides:getFace(TitlebarOverrides.FONT_OPTIONS.subtitle_face.setting_suffix)
	self.info_text_face = TitlebarOverrides:getFace(TitlebarOverrides.FONT_OPTIONS.info_text_face.setting_suffix)
	return original_TitlebarWidget_init(self, ...)
end

--------------------------------------------------------------------------------
-- Simple UI font logic
--------------------------------------------------------------------------------

local SIMPLE_UI_FONT_KEY = "coverbrowser"
local SIMPLE_UI_FONT_PATH_SETTING = "coverbrowser_font_path"
local SIMPLE_UI_FONT_NAME_SETTING = "coverbrowser_font_name"

local SIMPLE_UI_FONT_OPTIONS = {
	coverdeck_title_font = {
		setting_suffix = "coverdeck_title_font",
		label = _("Coverdeck Title"),
		default_face_name = "cfont",
	},
	coverdeck_info_font = {
		setting_suffix = "coverdeck_info_font",
		label = _("Coverdeck Info"),
		default_face_name = "cfont",
	},
	bottom_tab_font = {
		setting_suffix = "bottom_tab_font",
		label = _("Bottom Bar Tabs"),
		default_face_name = "cfont",
	},
	stats_value_font = {
		setting_suffix = "stats_value_font",
		label = _("Reading Stats Values"),
		default_face_name = "cfont",
	},
	stats_label_font = {
		setting_suffix = "stats_label_font",
		label = _("Reading Stats Labels"),
		default_face_name = "cfont",
	},
}

local SIMPLE_UI_FONT_OPTION_LIST = {
	SIMPLE_UI_FONT_OPTIONS.coverdeck_title_font,
	SIMPLE_UI_FONT_OPTIONS.coverdeck_info_font,
	SIMPLE_UI_FONT_OPTIONS.bottom_tab_font,
	SIMPLE_UI_FONT_OPTIONS.stats_value_font,
	SIMPLE_UI_FONT_OPTIONS.stats_label_font,
}

local SimpleUIOverrides = FontOverride:new{
	SETTINGS_KEY = SIMPLE_UI_FONT_KEY,
	FONT_PATH_SETTING = SIMPLE_UI_FONT_PATH_SETTING,
	FONT_NAME_SETTING = SIMPLE_UI_FONT_NAME_SETTING,
	FONT_OPTIONS = SIMPLE_UI_FONT_OPTIONS,
	FONT_OPTION_LIST = SIMPLE_UI_FONT_OPTION_LIST,
}

local function patchSimpleUI(plugin)
	local CoverDeck = require("desktop_modules/module_coverdeck")
	local ReadingStats = require("desktop_modules/module_reading_stats")

	local BottomBar = require("sui_bottombar")

	local SUIStyle = require("sui_style")
	local SUISettings = require("sui_store")
	local UI = require("sui_core")
	
	CoverDeck.face_title_override = SimpleUIOverrides:getFontPath(SimpleUIOverrides.FONT_OPTIONS.coverdeck_title_font.setting_suffix)
	CoverDeck.face_info_override = SimpleUIOverrides:getFontPath(SimpleUIOverrides.FONT_OPTIONS.coverdeck_info_font.setting_suffix)

	local original_BottomBar_buildTabCell = BottomBar.buildTabCell

	---@diagnostic disable-next-line: duplicate-set-field
	BottomBar.buildTabCell = function(action_id, active, tab_w, mode)
		local result = original_BottomBar_buildTabCell(action_id, active, tab_w, mode)
		local TextWidget = require("ui/widget/textwidget")

		for i, child in ipairs(result[1]) do
			for j, meta_child in ipairs(child) do
				if meta_child.text then
					local new_text_widget = TextWidget:new{
						text = meta_child.text,
						face = SimpleUIOverrides:getFace(SimpleUIOverrides.FONT_OPTIONS.bottom_tab_font.setting_suffix, meta_child.face.size),
						fgcolor = meta_child.fgcolor or UI.CLR_TEXT,
						--width = meta_child.width or 100,
						bold = meta_child.bold or false,
						alignment = "center",
					}
					result[1][i][j] = new_text_widget
				end
			end
		end
		return result
	end

	local original_ReadingStats_build = ReadingStats.build

	---@diagnostic disable-next-line: duplicate-set-field
	ReadingStats.build = function(w, ctx)
		local result = original_ReadingStats_build(w, ctx)
		if not result then return result end

		local TextWidget = require("ui/widget/textwidget")

		local Config = require("sui_config")

		local _BASE_RS_VAL_FS   = SUIStyle.FS_TITLE     -- 22: stat value (large numeric)
		local _BASE_RS_LBL_FS   = SUIStyle.FS_DETAIL    -- 15: stat label
		local _BASE_RS_PH_FS    = SUIStyle.FS_BODY      

		local scale     = Config.getModuleScale("reading_stats", ctx and ctx.pfx)
		local text_scale = scale * (Config.getRSTextScalePct() / 100)
		local _val_fs = math.max(8, math.floor(_BASE_RS_VAL_FS * text_scale))
		local _lbl_fs = math.max(6, math.floor(_BASE_RS_LBL_FS * text_scale))
		local _ph_fs  = math.max(8, math.floor(_BASE_RS_PH_FS  * scale))

		local stats_value_font = SimpleUIOverrides:getFace(SimpleUIOverrides.FONT_OPTIONS.stats_value_font.setting_suffix, _val_fs)
		local stats_label_font = SimpleUIOverrides:getFace(SimpleUIOverrides.FONT_OPTIONS.stats_label_font.setting_suffix, _lbl_fs)

		for i, child in ipairs(result[1][1]) do
			local widgets = child[1][1][1]
			local stat_num = widgets[1]
			local stat_label = widgets[2]
			-- logger.info("Ultimate Fonts: reading stats widget result: ", stat_num._inner.text, stat_label._inner.text)

			if stat_num._inner and stat_num._inner.text and stat_num._inner.face and stat_num._inner.face.size == _val_fs then
				local new_stat_num = TextWidget:new{
					text = stat_num._inner.text,
					face = stats_value_font,
					fgcolor = stat_num._inner.fgcolor or UI.CLR_TEXT,
					width = stat_num._inner.width or 100,
					bold = stat_num._inner.bold or false,
					alignment = "center",
				}
				result[1][1][i][1][1][1][1] = new_stat_num
			end
			if stat_label._inner and stat_label._inner.text and stat_label._inner.face and stat_label._inner.face.size == _lbl_fs then
				local new_stat_label = TextWidget:new{
					text = stat_label._inner.text,
					face = stats_label_font,
					fgcolor = stat_label._inner.fgcolor or UI.CLR_TEXT,
					width = stat_label._inner.width or 100,
					bold = stat_label._inner.bold or false,
					alignment = "center",
				}
				result[1][1][i][1][1][1][2] = new_stat_label
			end
		end

		return result
	end
	
end

userpatch.registerPatchPluginFunc("simpleui", patchSimpleUI)

--------------------------------------------------------------------------------
-- Book List Menu font logic
--------------------------------------------------------------------------------

local COVERBROWSER_FONT_KEY = "coverbrowser"
local COVERBROWSER_FONT_PATH_SETTING = "coverbrowser_font_path"
local COVERBROWSER_FONT_NAME_SETTING = "coverbrowser_font_name"

local COVERBROWSER_FONT_OPTIONS = {
	folder_title_font = {
		setting_suffix = "folder_title_font",
		label = _("Folder Title"),
		default_face_name = "cfont",
	},
	book_title_font = {
		setting_suffix = "book_title_font",
		label = _("Book Title"),
		default_face_name = "cfont",
	},
	book_authors_font = {
		setting_suffix = "book_authors_font",
		label = _("Book Authors"),
		default_face_name = "cfont",
	},
}

local COVERBROWSER_FONT_OPTION_LIST = {
	COVERBROWSER_FONT_OPTIONS.folder_title_font,
	COVERBROWSER_FONT_OPTIONS.book_title_font,
	COVERBROWSER_FONT_OPTIONS.book_authors_font,
}

local CoverBrowserOverrides = FontOverride:new{
	SETTINGS_KEY = COVERBROWSER_FONT_KEY,
	FONT_PATH_SETTING = COVERBROWSER_FONT_PATH_SETTING,
	FONT_NAME_SETTING = COVERBROWSER_FONT_NAME_SETTING,
	FONT_OPTIONS = COVERBROWSER_FONT_OPTIONS,
	FONT_OPTION_LIST = COVERBROWSER_FONT_OPTION_LIST,
}

local function patchCoverBrowser(plugin)
	local BookInfoManager = require("bookinfomanager")
    local ListMenu = require("listmenu")

    local ListMenuItem = userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")
    if not ListMenuItem then return end
    if ListMenuItem._fontpatch_applied then return end
    ListMenuItem._fontpatch_applied = true

    local original_update = ListMenuItem.update

    function ListMenuItem:update(...)
        local VerticalGroup = require("ui/widget/verticalgroup")
        local TextBoxWidget = require("ui/widget/textboxwidget")

        -- captured_bookinfo: { vgroup, wtitle, wauthors } — bookinfo path
        -- captured_dir:      first wide TextBoxWidget created for directories (wleft)
        -- captured_filename: last  wide TextBoxWidget created for files without bookinfo
        --                    (the repeat-loop creates several; the last one is the keeper)
        local captured_bookinfo = nil
        local captured_dir      = nil

        local orig_VG_new  = VerticalGroup.new
        local orig_TBW_new = TextBoxWidget.new

        VerticalGroup.new = function(klass, t, ...)
            local vg = orig_VG_new(klass, t, ...)
            if not captured_bookinfo and t and t[1] and type(t[1].text) == "string"
                and t[1].width and t[1].width > 100 then
                captured_bookinfo = { vgroup = vg, wtitle = t[1], wauthors = t[2] }
            end
            return vg
        end

        TextBoxWidget.new = function(klass, t, ...)
            local widget = orig_TBW_new(klass, t, ...)
            if t and type(t.text) == "string" and t.width and t.width > 100 then
                if self.is_directory and not captured_dir then
                    captured_dir = widget
                end
            end
            return widget
        end

        original_update(self, ...)
        VerticalGroup.new = orig_VG_new
        TextBoxWidget.new = orig_TBW_new

        -- Rebuild a TextBoxWidget with a new font path/size.
        local function rebuildWidget(widget, option_key, font_size, want_bold, want_italic)
            if not widget then return end
            local cur_face = widget.face
            local resolved
            if option_key then
				local font_options = CoverBrowserOverrides.FONT_OPTIONS
				local option_entry = font_options and font_options[option_key]
				if option_entry and option_entry.setting_suffix then
					resolved = CoverBrowserOverrides:getFontPath(option_entry.setting_suffix)
				elseif type(option_key) == "string" then
					-- Backward-compatible: accept a setting suffix or a fully resolved font path.
					resolved = CoverBrowserOverrides:getFontPath(option_key) or option_key
				end
            else
                resolved = cur_face and cur_face.ftname
            end
            local new_size = font_size or (cur_face and cur_face.orig_size) or 18
            if resolved == (cur_face and cur_face.ftname)
                and new_size == (cur_face and cur_face.orig_size) then return end
            local new_face = resolved and Font:getFace(resolved, new_size)
            if not new_face or new_face == cur_face then return end
            widget.face = new_face
            widget:free(true)
            widget:init()
        end

        -- Bookinfo found: apply title + authors fonts
        if captured_bookinfo and self.bookinfo_found and not self.is_directory then
            local book_title_font_path = CoverBrowserOverrides:getFontPath(CoverBrowserOverrides.FONT_OPTIONS.book_title_font.setting_suffix)
            local book_authors_font_path = CoverBrowserOverrides:getFontPath(CoverBrowserOverrides.FONT_OPTIONS.book_authors_font.setting_suffix)
            if book_title_font_path or book_authors_font_path then
                rebuildWidget(captured_bookinfo.wtitle,   book_title_font_path)
                rebuildWidget(captured_bookinfo.wauthors, book_authors_font_path)
            end
        end

        -- Directory: apply folder font
        if captured_dir and self.is_directory then
            local fp = CoverBrowserOverrides.FONT_OPTIONS.folder_title_font.setting_suffix
			local folder_font_path = CoverBrowserOverrides:getFontPath(fp)
            if folder_font_path then
                rebuildWidget(captured_dir, folder_font_path)
            end
        end
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)

--------------------------------------------------------------------------------
-- MENU INTEGRATION (Unified)
--------------------------------------------------------------------------------

local function getFontMenuSubsection(override, labels)
	labels = labels or {}
	local menu_text = labels.menu_text or _("Fonts")
	local shared_font_text = labels.shared_font_text or _("Shared font: %1")
	local use_shared_font_text = labels.use_shared_font_text or _("Use shared font: %1")
	local reset_item_text = labels.reset_item_text or _("Reset per-element overrides")
	local reset_confirm_text = labels.reset_confirm_text or _("Reset all per-element overrides for this section and make them inherit the shared font or built-in defaults?")

	local function buildSharedFontPickerTable()
		local item_table = {
			{
				text = _("Use default font"),
				enabled_func = function()
					return override:hasFontOverride()
				end,
				callback = function(touchmenu_instance)
					deferUIFontAction(function()
						G_reader_settings:delSetting(override.FONT_PATH_SETTING)
						G_reader_settings:delSetting(override.FONT_NAME_SETTING)
						UIManager:setDirty(nil, "ui")
					end, function()
						returnToParentMenu(touchmenu_instance)
					end)
				end,
				separator = true,
			},
		}

		local font_items = getGenericFontTable(ReaderFont, {
			setting_key_path = override.FONT_PATH_SETTING,
			setting_key_name = override.FONT_NAME_SETTING,
			save_path_as_name = false,
			restart_on_change = false,
			return_to_parent_on_change = true,
			mark_active_func = function(fname)
				return override:hasFontOverride() and fname == override:getFontBasePath()
			end,
		})
		for _, item in ipairs(font_items) do
			table.insert(item_table, item)
		end

		return makeRefreshableItemTable(item_table, buildSharedFontPickerTable)
	end

	local function getSharedFontPickerItem()
		return {
			text_func = function()
				local display_name
				if override:hasFontOverride() then
					display_name = getFontDisplayName(override:getFontBasePath(), G_reader_settings:readSetting(override.FONT_NAME_SETTING))
				else
					display_name = _("Built-in default font")
				end
				return T(shared_font_text, BD.wrap(display_name))
			end,
			sub_item_table_func = buildSharedFontPickerTable,
		}
	end

	local function buildSlotPickerTable(option)
		local item_table = {
			{
				text_func = function()
					local inherited_path, inherited_name, uses_shared_default = override:getInheritedFontPath(option.setting_suffix)
					local label = uses_shared_default and use_shared_font_text or _("Use default font: %1")
					return T(label, BD.wrap(getUIFontNameDisplay(inherited_path, inherited_name, not override:hasFontSlotOverride(option.setting_suffix))))
				end,
				enabled_func = function()
					return override:hasFontSlotOverride(option.setting_suffix)
				end,
				callback = function(touchmenu_instance)
					deferUIFontAction(function()
						override:clearFontSlotOverride(option.setting_suffix)
						UIManager:setDirty(nil, "ui")
					end, function()
						returnToParentMenu(touchmenu_instance)
					end)
				end,
				separator = true,
			},
		}

		local setting_keys = override:getFontSettingKeys(option.setting_suffix)
		local font_items = getGenericFontTable(ReaderFont, {
			setting_key_path = setting_keys.path,
			setting_key_name = setting_keys.name,
			save_path_as_name = false,
			restart_on_change = false,
			return_to_parent_on_change = true,
			mark_active_func = function(fname)
				return fname == override:getFontPath(option.setting_suffix)
			end,
		})
		for _, item in ipairs(font_items) do
			table.insert(item_table, item)
		end

		return makeRefreshableItemTable(item_table, function()
			return buildSlotPickerTable(option)
		end)
	end

	local function getSlotPickerItem(option)
		return {
			text_func = function()
				return T(_("%1: %2"), option.label, BD.wrap(override:getFontDisplay(option.setting_suffix)))
			end,
			sub_item_table_func = function()
				return buildSlotPickerTable(option)
			end,
		}
	end

	local function buildFontRootTable()
		local item_table = {
			getSharedFontPickerItem(),
			{
				text = reset_item_text,
				callback = function()
					UIManager:show(ConfirmBox:new({
						text = reset_confirm_text,
						ok_text = _("Reset"),
						ok_callback = function()
							deferUIFontAction(function()
								override:clearFontSlotOverrides(override:getOptionKeyList())
							end)
						end,
						cancel_text = _("Cancel"),
					}))
				end,
				separator = true,
			},
		}

		for _, option in ipairs(override:getOptionList()) do
			table.insert(item_table, getSlotPickerItem(option))
		end

		return makeRefreshableItemTable(item_table, buildFontRootTable)
	end

	return {
		text = menu_text,
		sub_item_table_func = buildFontRootTable,
	}
end

local function getDictionaryFontMenuItem()
	return {
		text_func = function()
			local dict_font = G_reader_settings:readSetting("dict_font")
			if dict_font then
				local display_name = dict_font
				local cre = require("document/credocument"):engineInit()
				local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(dict_font)
				if not font_filename then
					font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(dict_font, nil, true)
				end
				if font_filename and font_faceindex then
					display_name = FontList:getLocalizedFontName(font_filename, font_faceindex) or display_name
				end
				return T(_("Dictionary font: %1"), BD.wrap(display_name))
			end
			return _("Dictionary font")
		end,
		sub_item_table_func = function()
			return getGenericFontTable(ReaderFont, {
				setting_key_path = "dict_font",
				save_path_as_name = true,
				restart_on_change = false,
				mark_active_func = function(fname, fparams)
					return fparams == G_reader_settings:readSetting("dict_font")
				end,
			})
		end,
	}
end

local function getUIFontMenuItem()
	local function buildDefaultUIFontPickerTable()
		return makeRefreshableItemTable(getGenericFontTable(ReaderFont, {
			setting_key_path = "uifont_path",
			setting_key_name = "uifont_name",
			save_path_as_name = false,
			restart_on_change = true,
			return_to_parent_on_change = true,
			mark_active_func = function(fname)
				return fname == getDefaultUIFontPath()
			end,
		}), buildDefaultUIFontPickerTable)
	end

	local function getDefaultUIFontPickerItem()
		return {
			text_func = function()
				local current_name = G_reader_settings:readSetting("uifont_name")
				return T(_("Default UI font: %1"), BD.wrap(getFontDisplayName(getDefaultUIFontPath(), current_name)))
			end,
			sub_item_table_func = buildDefaultUIFontPickerTable,
		}
	end

	local function buildUIFontPickerTable(option)
		local setting_keys = getUIFontSettingKeys(option.fontmap_key)
		local item_table = {
			{
				text_func = function()
					local default_name = G_reader_settings:readSetting("uifont_name")
					return T(_("Use default UI font: %1"), BD.wrap(getUIFontNameDisplay(getDefaultUIFontPath(), default_name, not hasUIFontOverride(option))))
				end,
				enabled_func = function()
					return hasUIFontOverride(option)
				end,
				callback = function(touchmenu_instance)
					deferUIFontChange(function()
						clearUIFontOptionOverride(option)
					end)
				end,
				separator = true,
			},
		}

		local font_items = getGenericFontTable(ReaderFont, {
			setting_key_path = setting_keys.path,
			setting_key_name = setting_keys.name,
			save_path_as_name = false,
			restart_on_change = true,
			return_to_parent_on_change = true,
			mark_active_func = function(fname)
				return fname == getUIFontBasePath(option)
			end,
		})
		for _, item in ipairs(font_items) do
			table.insert(item_table, item)
		end

		return makeRefreshableItemTable(item_table, function()
			return buildUIFontPickerTable(option)
		end)
	end

	local function getUIFontPickerItem(option)
		local setting_keys = getUIFontSettingKeys(option.fontmap_key)
		return {
			text_func = function()
				local current_name = G_reader_settings:readSetting(setting_keys.name)
				return T(_("%1: %2"), option.label, BD.wrap(getUIFontNameDisplay(getUIFontBasePath(option), current_name, not hasUIFontOverride(option))))
			end,
			sub_item_table_func = function()
				return buildUIFontPickerTable(option)
			end,
		}
	end

	local function buildUIFontGroupApplyTable(group)
		local shared_path = getUIFontGroupSharedBasePath(group)
		return makeRefreshableItemTable(getGenericFontTable(ReaderFont, {
			restart_on_change = true,
			return_to_parent_on_change = true,
			mark_active_func = function(fname)
				return shared_path ~= nil and fname == shared_path
			end,
			on_select_func = function(touchmenu_instance, font_filename, font_name)
				if not font_filename then
					UIManager:show(InfoMessage:new({ text = _("Could not determine filename for this font.") }))
					return
				end
				local saved_font_filename = font_filename
				local saved_font_name = font_name
				deferUIFontAction(function()
					setUIFontOverrides(group.options, saved_font_filename, saved_font_name)
				end, function()
					returnToParentMenu(touchmenu_instance)
					showUIFontRestartPrompt()
				end)
			end,
		}), function()
			return buildUIFontGroupApplyTable(group)
		end)
	end

	local function buildUIFontGroupTable(group)
		local item_table = {
			{
				text_func = function()
					local shared_path = getUIFontGroupSharedBasePath(group)
					if shared_path then
						return T(_("Set all fonts in this group: %1"), BD.wrap(getFontDisplayName(shared_path)))
					end
					return _("Set all fonts in this group")
				end,
				sub_item_table_func = function()
					return buildUIFontGroupApplyTable(group)
				end,
				separator = true,
			},
			{
				text = _("Reset overrides in this group"),
				callback = function(touchmenu_instance)
					UIManager:show(ConfirmBox:new({
						text = T(_("Reset all UI font overrides in %1?"), group.label),
						ok_text = _("Reset"),
						ok_callback = function()
							deferUIFontChange(function()
								clearUIFontOverrides(group.options)
							end)
						end,
						cancel_text = _("Cancel"),
					}))
				end,
				separator = true,
			},
		}

		for _, option in ipairs(group.options) do
			table.insert(item_table, getUIFontPickerItem(option))
		end

		return makeRefreshableItemTable(item_table, function()
			return buildUIFontGroupTable(group)
		end)
	end

	local function buildUIFontRootTable()
		local item_table = {
			getDefaultUIFontPickerItem(),
			{
				text = _("Reset all UI font overrides"),
				callback = function(touchmenu_instance)
					UIManager:show(ConfirmBox:new({
						text = _("Reset all per-slot UI font overrides and make every slot inherit the default UI font?"),
						ok_text = _("Reset"),
						ok_callback = function()
							deferUIFontChange(function()
								clearUIFontOverrides(UI_FONT_OPTION_LIST)
							end)
						end,
						cancel_text = _("Cancel"),
					}))
				end,
				separator = true,
			},
		}

		for _, group in ipairs(UI_FONT_GROUP_LIST) do
			local current_group = group
			table.insert(item_table, {
				text = current_group.label,
				sub_item_table_func = function()
					return buildUIFontGroupTable(current_group)
				end,
			})
		end

		return makeRefreshableItemTable(item_table, buildUIFontRootTable)
	end

	return {
		text = _("UI font slots"),
		sub_item_table_func = buildUIFontRootTable,
	}
end

local function hasMenuItem(order_section, item_id)
	for _, existing_item_id in ipairs(order_section) do
		if existing_item_id == item_id then
			return true
		end
	end
	return false
end

local function patchSettingsMenu(menu, order)
	menu.menu_items.custom_fonts = {
		text = _("Ultimate Fonts"),
		sub_item_table_func = function()
			return {
				getUIFontMenuItem(),
				getFontMenuSubsection(MainMenuFontOverrides, {
					menu_text = _("Main menu fonts")}),
				getFontMenuSubsection(TitlebarOverrides, {
					menu_text = _("Titlebar Widget fonts")}),
				getFontMenuSubsection(DictQuickLookupOverrides, {
					menu_text = _("Dictionary fonts")}),
				getFontMenuSubsection(InfoMessageOverrides, {
					menu_text = _("Info Message & Confirm Box fonts")}),
				getFontMenuSubsection(ButtonOverrides, {
					menu_text = _("Button fonts")}),
				getFontMenuSubsection(CoverBrowserOverrides, {
					menu_text = _("Cover Browser fonts")}),
				getFontMenuSubsection(SimpleUIOverrides, {
					menu_text = _("Simple UI fonts")}),
			}
		end,
	}

	if not hasMenuItem(order.setting, "custom_fonts") then
		table.insert(order.setting, "custom_fonts")
	end
end

local original_FileManagerMenu_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
---@diagnostic disable-next-line: duplicate-set-field
function FileManagerMenu:setUpdateItemTable()
	patchSettingsMenu(self, require("ui/elements/filemanager_menu_order"))
	original_FileManagerMenu_setUpdateItemTable(self)
end

local original_ReaderMenu_setUpdateItemTable = ReaderMenu.setUpdateItemTable
---@diagnostic disable-next-line: duplicate-set-field
function ReaderMenu:setUpdateItemTable()
	patchSettingsMenu(self, require("ui/elements/reader_menu_order"))
	original_ReaderMenu_setUpdateItemTable(self)
end

logger.info("Custom UI fonts patch applied")
