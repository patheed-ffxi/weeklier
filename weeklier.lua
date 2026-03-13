require('common')
local bit = require('bit')
local imgui = require('imgui')

addon.name    = 'weeklier'
addon.author  = 'custom'
addon.version = '0.1a'
addon.desc    = 'Tracks weekly quest completion across characters.'
addon.link    = ''

local json = require('json')

-- Load key item data (name -> numeric ID mapping).
-- Uses pcall so the addon still loads if the file is missing or malformed.
local KEY_ITEMS = nil
do
    local ok, result = pcall(require, 'data.key_item')
    if ok and type(result) == 'table' then
        KEY_ITEMS = result
    else
        print(string.format('\30\02[weeklier]\30\01 \30\68ERROR: Failed to load data/key_item.lua: %s\30\01',
            tostring(result)))
        print('\30\02[weeklier]\30\01 Key item verification will be unavailable.')
        KEY_ITEMS = {}
    end
end

-- ============================================================================
-- Config - QUEST DEFINITIONS
-- ============================================================================
-- Each quest has:
--   name               : display name
--
-- Non-ENM weekly quest status is derived from packet data and/or chat detection:
--   quest_log_id        : numeric log ID (0=San d'Oria, 1=Bastok, 2=Windurst,
--                         3=Jeuno, 4=Other, 5=Outlands, 6=Aht Urhgan,
--                         7=Crystal War, 8=Abyssea, 9=Adoulin, 10=Coalition)
--   quest_id            : numeric quest ID within that log (0-255 bit index)
--                         Used with is_quest_active() from packet 0x056 data.
--
-- Key-item verification (from key_item.lua names, checked via packet 0x055):
--   ki_quest_active     : KI name that the player receives when the quest is accepted.
--                         Having this KI = quest needs to be completed (NEED TO COMPLETE).
--                         KI removal is detected via 0x055 packet updates and triggers
--                         READY TO TURN IN status (the KI is consumed when the objective
--                         is completed, meaning the player needs to go turn in the quest).
--   ki_active_is_completion : boolean. If true, ki_quest_active removal goes straight
--                         to COMPLETED instead of READY TO TURN IN. Use for quests
--                         where consuming the KI IS the completion (no turn-in step).
--   ki_quest_incomplete : KI name that the player holds while the quest is in progress.
--                         Having this KI = ready to turn in (READY TO TURN IN).
--                         KI removal is detected via 0x055 packet updates and triggers
--                         COMPLETED status (the KI is consumed on turn-in).
--
-- Status derivation for non-ENM quests (current character only):
--   COMPLETED        : ki_quest_incomplete KI removed (turn-in), OR
--                      ki_quest_active KI removed with ki_active_is_completion, OR
--                      complete_phrase detected in chat, OR stored as completed
--   READY TO TURN IN : player has ki_quest_incomplete KI, OR
--                      ki_quest_active KI removed (objective done, needs turn-in)
--   NEED TO COMPLETE : quest is active (0x056), has ki_quest_active KI, OR
--                      flag_phrase detected in chat
--   NOT STARTED      : no active indicators and no stored progress
--
-- Chat-based flag detection (alternative to quest_log_id/quest_id):
--   flag_phrase       : if present, the addon will watch for this phrase in chat.
--                       When seen, the quest is advanced to NEED TO COMPLETE.
--                       Useful for quests that don't appear in the quest log
--                       (e.g. bugged quests) but still have a chat message
--                       when flagged. The phrase is matched after normalizing
--                       (lowercase, stripped control chars).
--
-- Chat-based completion detection:
--   complete_phrase   : if present, the addon will watch for this phrase in chat.
--                       When seen, the quest is advanced to COMPLETED.
--                       Useful for quests that are bugged (e.g. always show as
--                       active in the quest log) and don't have a ki_quest_incomplete
--                       KI removal to detect turn-in.
--
-- Status is derived from live packet data for the current character and
-- persisted to JSON so it can be viewed when logged into a different character.
--
-- For ENM quests (type = 'enm'):
--   ki_quest_active     : KI name (from key_item.lua) used to verify possession via packet.
--   ki_display_name     : The human-readable KI name as it appears in the chat message
--                         "Obtained key item: <ki_display_name>."  Used to detect when the
--                         KI was obtained and start the cooldown timer.
--   enm_cooldown_days   : Number of real days for the cooldown (default 5).
--   ENMs are displayed in their own section in the UI, separate from weekly quests.
--   ENM cooldown data is NOT reset on weekly rollover - it uses its own timer.
--
-- For kill-based quests (type = 'kill_mob'):
--   kill_mob            : mob name to watch for in "defeats the <mob>" messages
--   No flag/complete phrases needed - killing the mob IS the quest.
--
--   Kill detection works in two steps within a short time window:
--     1. "Someone defeats the <kill_mob>." appears in chat
--     2. "<your character> gains <x> experience points." appears shortly after
--   Both must occur within KILL_CONFIRM_WINDOW seconds to count.
--   Once confirmed, the quest goes straight to COMPLETED.
-- ============================================================================

-- How many seconds after a "defeats the X" message to wait for the XP message
local KILL_CONFIRM_WINDOW = 5.0

-- Debug mode: when true, logs detailed diagnostic info about status changes,
-- packet processing, KI checks, quest active checks, etc.
local debug_mode = false


local QUESTS = {
    {
        name                = 'Secrets of Ovens Lost',
        quest_log_id        = 4,
        quest_id            = 73,
        ki_quest_incomplete = 'TAVNAZIAN_COOKBOOK',
    },
    {
        name                = 'Uninvited Guests',
        -- No quest_log_id/quest_id: quest is bugged and always shows as active.
        ki_quest_active     = 'MONARCH_LINN_PATROL_PERMIT',
        complete_phrase     = 'You deserve something for putting your neck on the line',
    },
    {
        name                = 'Spice Gals',
        -- No quest_log_id/quest_id: quest is bugged and doesn't appear in active quests.
        ki_quest_incomplete = 'RIVERNEWORT',
        flag_phrase         = 'you find yourself in possession of a sprig of Rivernewort, then I should dearly love to prepare',
    },
    {
        name                    = 'Requiem of Sin',
        ki_quest_active         = 'LETTER_FROM_THE_MITHRAN_TRACKERS',
        ki_active_is_completion = true,
    },
    {
        name                = 'Monarch Linn ENM',
        type                = 'enm',
        ki_quest_active     = 'MONARCH_BEARD',
        ki_display_name     = 'Monarch beard',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Test Your Mite',
        type                = 'enm',
        ki_quest_active     = 'ASTRAL_COVENANT',
        ki_display_name     = 'Astral Covenant',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Mine Shaft #2716 ENM',
        type                = 'enm',
        ki_quest_active     = 'SHAFT_GATE_OPERATING_DIAL',
        ki_display_name     = 'Shaft Gate Operating Dial',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Boneyard Gully ENM',
        type                = 'enm',
        ki_quest_active     = 'MIASMA_FILTER',
        ki_display_name     = 'Miasma Filter',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Bearclaw Pinnacle ENM',
        type                = 'enm',
        ki_quest_active     = 'ZEPHYR_FAN',
        ki_display_name     = 'Zephyr Fan',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Dem: You Are What You Eat',
        type                = 'enm',
        ki_quest_active     = 'CENSER_OF_ANTIPATHY',
        ki_display_name     = 'Censer of Antipathy',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Mea: Playing Host',
        type                = 'enm',
        ki_quest_active     = 'CENSER_OF_ANIMUS',
        ki_display_name     = 'Censer of Animus',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Holla: Simulant',
        type                = 'enm',
        ki_quest_active     = 'CENSER_OF_ABANDONMENT',
        ki_display_name     = 'Censer of Abandonment',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Vahzl: Pulling the Plug',
        type                = 'enm',
        ki_quest_active     = 'CENSER_OF_ACRIMONY',
        ki_display_name     = 'Censer of Acrimony',
        enm_cooldown_days   = 5,
    },
    -- -----------------------------------------------------------------------
    -- Kill-based quest: no flag or turn-in, just kill the mob and get XP.
    -- "defeats the <kill_mob>" + "<you> gains X experience points" = COMPLETED.
    -- -----------------------------------------------------------------------
    {
         name     = 'Kill Highwind',
         type     = 'kill_mob',
         kill_mob = 'Highwind',
    },
}

-- ============================================================================
-- Eco Warrior Config
-- ============================================================================
-- Eco Warriors are a special round-robin set: three quests (one per nation),
-- only one can be completed per week, and each must be completed before it can
-- be repeated. e.g. if you do Sandy week 1, you must do Bastok or Windy week 2
-- before you can do Sandy again.
--
-- Status per nation:
--   'Available'     - can be flagged this week
--   'Flagged'       - quest is currently active (quest log or has KI)
--   'Completed'     - completed this week
--   'Not Available' - another nation was flagged/completed this week, OR
--                     this nation was completed more recently than others
--
-- Stored per character in data[char].eco[nation_key] = {
--   completed_week = "2026-W10" or nil  (the week key when last completed)
--   stored_status  = "Available" etc.   (persisted for cross-char viewing)
-- }
-- ============================================================================
local ECO_WARRIORS = {
    {
        nation              = "San d'Oria",
        key                 = 'sandoria',
        quest_log_id        = 0,
        quest_id            = 97,
        ki_quest_incomplete = 'INDIGESTED_STALAGMITE',
    },
    {
        nation              = 'Bastok',
        key                 = 'bastok',
        quest_log_id        = 1,
        quest_id            = 65,
        ki_quest_incomplete = 'INDIGESTED_ORE',
    },
    {
        nation              = 'Windurst',
        key                 = 'windurst',
        quest_log_id        = 2,
        quest_id            = 84,
        ki_quest_incomplete = 'INDIGESTED_MEAT',
    },
}

-- ============================================================================
-- State
-- ============================================================================
local save_path                             -- set in load_cb (addon.path available then)
local show_window = { false }               -- imgui bool wrapper
local data = {}                             -- { [char_name] = { week, quests, enms, eco }, _hidden = { [name] = true } }
local current_char                          -- detected from party info
local last_packet_char                      -- tracks which char the packet-derived bitmaps belong to

-- Hidden quests (global UI preference, not per-character).
-- Stored as data._hidden = { [quest_name] = true, ... }
-- Loaded/saved alongside all other data in the same JSON file.
local hidden_quests = {}

local function is_quest_hidden(quest_name)
    return hidden_quests[quest_name] == true
end

local function set_quest_hidden(quest_name, hide)
    if hide then
        hidden_quests[quest_name] = true
    else
        hidden_quests[quest_name] = nil
    end
    data._hidden = hidden_quests
end

-- Kill-mob tracking: when we see "defeats the X", we store the quest indices
-- and a timestamp. If an XP message arrives within KILL_CONFIRM_WINDOW we
-- advance those quests to COMPLETED.
-- { [quest_index] = os.clock() timestamp of the "defeats" message }
local pending_kills = {}

-- ============================================================================
-- Key Item Tracking (packet 0x055)
-- ============================================================================
-- Bitmap of obtained key items.  Indexed [table_index][dword_index] = uint32.
-- table_index 0-6, each table has 16 uint32s = 512 bits = 512 key items.
local ki_bitmap = {}

-- Previous snapshot of ki_bitmap, used to detect KI removals between packets.
-- When a tracked KI transitions from "has" to "doesn't have", the addon
-- updates the quest status accordingly (see process_ki_removals).
local prev_ki_bitmap = {}

-- Reverse lookup: uppercase key item name -> numeric ID
-- Built once from KEY_ITEMS at load time.
local ki_name_to_id = {}

-- keyed by log_id, value = { [0]=u32, ... [7]=u32 }
local active_quest_blocks = {}

local QUEST_OFFER_PORT_TO_LOG_ID = {
    [0x0050] = 0,   -- San d'Oria
    [0x0058] = 1,   -- Bastok
    [0x0060] = 2,   -- Windurst
    [0x0068] = 3,   -- Jeuno
    [0x0070] = 4,   -- Other Areas
    [0x0078] = 5,   -- Outlands
    [0x0080] = 6,   -- Aht Urhgan
    [0x0088] = 7,   -- Crystal War
    [0x00E0] = 8,   -- Abyssea
    [0x00F0] = 9,   -- Adoulin
    [0x0100] = 10,  -- Coalition
}


-- ============================================================================
-- Logging
-- ============================================================================
local function log(msg)
    print(string.format('\30\02[weeklier]\30\01 %s', msg))
end

local function dlog(msg)
    if not debug_mode then return end
    print(string.format('\30\02[weeklier:DBG]\30\01 %s', msg))
end

local function build_ki_lookup()
    if not KEY_ITEMS or next(KEY_ITEMS) == nil then
        log('WARNING: Key item data is empty - KI-based quest detection will not work.')
        return
    end
    local count = 0
    for name, id in pairs(KEY_ITEMS) do
        ki_name_to_id[string.upper(name)] = id
        count = count + 1
    end
    dlog(string.format('Built KI lookup: %d entries.', count))
end

-- Read a little-endian uint32 from a binary string at 1-based offset.
local function u32le(s, offset)
    local b1, b2, b3, b4 = string.byte(s, offset, offset + 3)
    if not b1 or not b2 or not b3 or not b4 then return 0 end
    return b1 + bit.lshift(b2, 8) + bit.lshift(b3, 16) + bit.lshift(b4, 24)
end

-- Read a little-endian uint16 from a binary string at 1-based offset.
local function u16le(s, offset)
    local b1, b2 = string.byte(s, offset, offset + 1)
    if not b1 or not b2 then return 0 end
    return b1 + bit.lshift(b2, 8)
end

local function read_u32x8(pkt)
    local t = {}
    for i = 0, 7 do
        t[i] = u32le(pkt, 0x04 + 1 + (i * 4))
    end
    return t
end

-- Check whether the player currently holds a key item by numeric ID.
local function has_key_item(ki_id)
    local table_index = math.floor(ki_id / 512)
    local bit_index   = ki_id % 512
    local dword_index = math.floor(bit_index / 32)
    local bit_offset  = bit_index % 32

    local tbl = ki_bitmap[table_index]
    if not tbl then return false end
    local dword = tbl[dword_index] or 0
    return bit.band(dword, bit.lshift(1, bit_offset)) ~= 0
end

-- Check whether the player previously held a key item (before the latest 0x055 update).
local function had_key_item(ki_id)
    local table_index = math.floor(ki_id / 512)
    local bit_index   = ki_id % 512
    local dword_index = math.floor(bit_index / 32)
    local bit_offset  = bit_index % 32

    local tbl = prev_ki_bitmap[table_index]
    if not tbl then return false end
    local dword = tbl[dword_index] or 0
    return bit.band(dword, bit.lshift(1, bit_offset)) ~= 0
end

-- Resolve a quest's key_item config string to a numeric ID (cached per quest).
local ki_id_cache = {}
local function resolve_ki_id(ki_name)
    if not ki_name or ki_name == '' then return nil end
    local upper = string.upper(ki_name)
    if ki_id_cache[upper] ~= nil then return ki_id_cache[upper] end
    local id = ki_name_to_id[upper]
    ki_id_cache[upper] = id or false
    return id or nil
end

local function is_bit_set_in_block(block, bit_index)
    if not block or bit_index < 0 or bit_index > 255 then
        return false
    end

    local dword_index = math.floor(bit_index / 32)
    local bit_in_dword = bit_index % 32
    local value = block[dword_index] or 0

    return bit.band(value, bit.lshift(1, bit_in_dword)) ~= 0
end

local function is_quest_active(log_id, quest_id)
    local block = active_quest_blocks[log_id]
    return is_bit_set_in_block(block, quest_id)
end

local function get_active_quest_ids(log_id)
    local out = {}
    local block = active_quest_blocks[log_id]
    if not block then
        return out
    end

    for quest_id = 0, 255 do
        if is_bit_set_in_block(block, quest_id) then
            out[#out + 1] = quest_id
        end
    end

    return out
end


-- ============================================================================
-- Week Key - used to auto-reset when a new week starts
-- ============================================================================
-- Returns a string like "2026-W11" representing ISO week.
-- Weekly reset: midnight Monday JST (Japan Standard Time, UTC+9).
-- This is a fixed point in time: Sunday 15:00 UTC.
-- All calculations use UTC so the reset is correct for every timezone.

-- Returns the current time as a UTC unix timestamp.
-- os.time() returns seconds since Unix epoch (Jan 1 1970 00:00 UTC),
-- which is already a UTC-based value on all standard platforms.
local function now_utc()
    return os.time()
end

-- Returns the UTC unix timestamp of the next weekly reset.
-- Reset = midnight Monday JST = Sunday 15:00 UTC.
-- If we are currently past that moment, returns next week's reset.
local function get_next_reset_time()
    local utc = now_utc()
    local t = os.date('!*t', utc)

    -- Lua wday: Sunday=1 .. Saturday=7
    -- We want next Sunday 15:00 UTC (which is Monday 00:00 JST).
    local days_until_sunday = (1 - t.wday) % 7  -- 0 if today is Sunday

    -- Compute Sunday 15:00 UTC from today's UTC midnight
    local today_midnight_utc = utc - (t.hour * 3600 + t.min * 60 + t.sec)
    local reset = today_midnight_utc + days_until_sunday * 86400 + 15 * 3600

    -- If we're already past that reset (or it's exactly now), jump to next week
    if utc >= reset then
        reset = reset + 7 * 86400
    end

    return reset
end

-- Format a duration in seconds as "Xd Xh Xm Xs"
local function format_countdown(seconds)
    if seconds <= 0 then return 'NOW!' end
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if d > 0 then
        return string.format('%dd %dh %dm %ds', d, h, m, s)
    elseif h > 0 then
        return string.format('%dh %dm %ds', h, m, s)
    else
        return string.format('%dm %ds', m, s)
    end
end

local function get_week_key()
    -- The week key is based on when the last reset occurred (Sunday 15:00 UTC).
    -- We find the most recent reset and derive the ISO week from that moment.
    local next_reset = get_next_reset_time()
    local last_reset = next_reset - 7 * 86400
    local t = os.date('!*t', last_reset)
    -- ISO weekday: Monday=1 .. Sunday=7
    local iso_wday = t.wday == 1 and 7 or (t.wday - 1)
    local thursday = last_reset + (4 - iso_wday) * 86400
    local thu_t = os.date('!*t', thursday)
    -- Compute Jan 1 00:00 UTC of that year using yday (day of year) from thursday.
    -- thursday is a UTC epoch timestamp, so subtracting (yday-1) days + time-of-day
    -- gives us Jan 1 00:00 UTC as an epoch timestamp without any local time conversion.
    local jan1 = thursday - (thu_t.yday - 1) * 86400 - thu_t.hour * 3600 - thu_t.min * 60 - thu_t.sec
    local week_num = math.floor((thursday - jan1) / 604800) + 1
    return string.format('%d-W%02d', thu_t.year, week_num)
end

-- ============================================================================
-- Persistence
-- ============================================================================
local function save_data()
    if not save_path then return end
    local f = io.open(save_path, 'w+')
    if not f then
        log('Failed to open save file for writing.')
        return
    end
    f:write(json.encode(data))
    f:close()
end

local function load_data()
    if not save_path then return end
    local f = io.open(save_path, 'r')
    if not f then
        data = {}
        return
    end
    local raw = f:read('*a')
    f:close()

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        log('Failed to parse save file; starting fresh.')
        data = {}
        return
    end
    data = decoded

    -- Restore hidden quests from saved data
    if type(data._hidden) == 'table' then
        hidden_quests = data._hidden
    else
        hidden_quests = {}
        data._hidden = hidden_quests
    end
end

local function normalize_string(s)
    if not s or s == '' then return nil end

    -- Strip FFXI color/control codes:
    -- 0x1E, 0x1F, 0x7F, NULL, and all ASCII control chars
    s = s:gsub('[%z\1-\31\127]', '')

    -- Trim whitespace
    s = s:gsub('^%s+', ''):gsub('%s+$', '')

    -- Normalize case
    s = s:lower()

    return (s ~= '' and s or nil)
end

-- ============================================================================
-- Character Data Helpers
-- ============================================================================
-- Ensures the character entry exists and is for the current week.
-- On week rollover, only COMPLETED quests are reset (flagged/in-progress
-- quests persist in-game and don't need to be re-accepted).
local function ensure_char(name)
    if not name or name == '' then return nil end
    local week = get_week_key()

    if not data[name] then
        dlog(string.format('ensure_char: creating new entry for "%s" week=%s', name, week))
        data[name] = { week = week, quests = {}, enms = {} }
    end

    -- Ensure enms table exists (for saves from before ENM support)
    if not data[name].enms then
        data[name].enms = {}
    end

    -- Week rollover - only reset COMPLETED quests (flagged/in-progress quests
    -- persist across the weekly boundary in-game and don't need to be re-flagged)
    if data[name].week ~= week then
        log(string.format('New week detected for %s - resetting completed quests. (old=%s, new=%s)',
            name, data[name].week, week))
        data[name].week = week
        for _, q in ipairs(QUESTS) do
            if q.type ~= 'enm' then
                local cur = data[name].quests[q.name]
                if cur == 'COMPLETED' then
                    if q.type == 'kill_mob' then
                        data[name].quests[q.name] = 'NEED TO COMPLETE'
                    else
                        data[name].quests[q.name] = 'NOT STARTED'
                    end
                    dlog(string.format('  Reset %s: COMPLETED -> %s', q.name, data[name].quests[q.name]))
                end
            end
        end
    end

    -- Ensure every non-ENM quest from QUESTS list has an entry
    for _, q in ipairs(QUESTS) do
        if q.type ~= 'enm' then
            if not data[name].quests[q.name] then
                -- Kill quests are always available, so default to NEED TO COMPLETE
                if q.type == 'kill_mob' then
                    data[name].quests[q.name] = 'NEED TO COMPLETE'
                else
                    data[name].quests[q.name] = 'NOT STARTED'
                end
            end
        end
    end

    -- Ensure every ENM has an entry in enms table
    for _, q in ipairs(QUESTS) do
        if q.type == 'enm' then
            if not data[name].enms[q.name] then
                data[name].enms[q.name] = {}   -- ki_obtained_time = nil initially
            end
        end
    end

    -- Ensure eco warrior data exists (never auto-reset - tracks round-robin cycle)
    if not data[name].eco then
        data[name].eco = {}
    end
    for _, ew in ipairs(ECO_WARRIORS) do
        if not data[name].eco[ew.key] then
            data[name].eco[ew.key] = {}  -- completed_week = nil initially
        end
    end

    return data[name]
end

local function get_current_char_name()
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return nil end
    local name = party:GetMemberName(0)
    if not name or name == '' then return nil end
    return name
end

-- Cache of last derived status per quest name, to avoid spamming debug logs every frame.
-- Declared here (before clear_packet_state) so it can be cleared on character change.
local last_derived_status = {}

-- Clear all packet-derived state (KI bitmaps, quest blocks, derived status cache).
-- Must be called whenever the logged-in character changes so that stale data from
-- the previous character is not mistakenly compared against the new character's
-- incoming packets (which would cause false KI "removal" detections).
local function clear_packet_state()
    ki_bitmap = {}
    prev_ki_bitmap = {}
    active_quest_blocks = {}
    last_derived_status = {}
    dlog('Cleared packet-derived state (character change).')
end

-- Checks if the character has changed since the last packet processing and, if so,
-- clears stale packet state. Call this at the top of packet handlers.
local function check_packet_char_change()
    local name = get_current_char_name()
    if not name then return end
    if last_packet_char and last_packet_char ~= name then
        log(string.format('Character change detected (%s -> %s) - clearing packet state.',
            last_packet_char, name))
        clear_packet_state()
    end
    last_packet_char = name
end

-- ============================================================================
-- State Management
-- ============================================================================
-- Advance state forward (never go backwards).
-- Order: NOT STARTED -> NEED TO COMPLETE -> READY TO TURN IN -> COMPLETED
local function try_advance(char_name, quest_name, new_status)
    local cd = ensure_char(char_name)
    if not cd then
        dlog(string.format('try_advance: ensure_char failed for "%s"', tostring(char_name)))
        return
    end

    local cur = cd.quests[quest_name] or 'NOT STARTED'

    local order = {
        ['NOT STARTED']      = 1,
        ['NEED TO COMPLETE'] = 2,
        ['READY TO TURN IN'] = 3,
        ['COMPLETED']        = 4,
    }

    local cur_order = order[cur] or 0
    local new_order = order[new_status] or 0

    if new_order > cur_order then
        cd.quests[quest_name] = new_status
        log(string.format('%s - %s -> %s', quest_name, cur, new_status))
        save_data()
    else
        dlog(string.format('try_advance BLOCKED: %s - %s (ord %d) -> %s (ord %d)',
            quest_name, cur, cur_order, new_status, new_order))
    end
end

-- ============================================================================
-- Packet-Based Status Derivation (non-ENM, non-kill_mob quests)
-- ============================================================================
-- Derives the current status from 0x055 (KI) and 0x056 (quest) packet data,
-- combined with stored status (which may have been set by chat detection,
-- KI removal events, or flag_phrase/complete_phrase).
-- Only runs for the currently logged-in character.
--
-- Status strings:
--   'NOT STARTED'      - no active indicators, no stored progress
--   'NEED TO COMPLETE' - quest active (0x056), has ki_quest_active, or stored
--                         (e.g. from flag_phrase)
--   'READY TO TURN IN' - has ki_quest_incomplete, or stored (e.g. from
--                         ki_quest_active removal)
--   'COMPLETED'        - stored as completed (from KI removal, complete_phrase,
--                         or ki_active_is_completion)
--

local function derive_quest_status(q, stored_status)
    local result

    -- If stored status is already COMPLETED this week, keep it
    if stored_status == 'COMPLETED' then
        result = 'COMPLETED'
    else
        -- Quest active check (packet 0x056)
        local quest_active = false
        if q.quest_log_id and q.quest_id then
            quest_active = is_quest_active(q.quest_log_id, q.quest_id)
        end

        -- KI checks (packet 0x055)
        local has_ki_active = false
        if q.ki_quest_active and q.ki_quest_active ~= '' then
            local ki_id = resolve_ki_id(q.ki_quest_active)
            if ki_id then
                has_ki_active = has_key_item(ki_id)
            end
        end

        local has_ki_incomplete = false
        if q.ki_quest_incomplete and q.ki_quest_incomplete ~= '' then
            local ki_id = resolve_ki_id(q.ki_quest_incomplete)
            if ki_id then
                has_ki_incomplete = has_key_item(ki_id)
            end
        end

        -- ki_quest_incomplete: having it means you need to turn in
        if has_ki_incomplete then
            result = 'READY TO TURN IN'
        -- ki_quest_active: having it means quest accepted, need to go complete it
        elseif has_ki_active then
            result = 'NEED TO COMPLETE'
        -- Quest is active but no specific KI -> need to complete
        -- UNLESS: quest has ki_quest_active configured and the KI is absent,
        -- meaning the objective was completed (KI consumed). In that case,
        -- respect the stored status (likely READY TO TURN IN from KI removal).
        elseif quest_active then
            local ki_active_consumed = (q.ki_quest_active and q.ki_quest_active ~= '' and not has_ki_active)
            if ki_active_consumed and stored_status == 'READY TO TURN IN' then
                result = 'READY TO TURN IN'
            else
                result = 'NEED TO COMPLETE'
            end
        else
            -- Quest is not active and no KIs present - use stored status
            result = stored_status or 'NOT STARTED'
        end

        -- Debug: only log when the derived result changes from last time
        if debug_mode and last_derived_status[q.name] ~= result then
            local qa_str = 'n/a'
            if q.quest_log_id and q.quest_id then
                qa_str = tostring(quest_active)
            end
            local ki_a_str = 'n/a'
            if q.ki_quest_active and q.ki_quest_active ~= '' then
                local ki_id = resolve_ki_id(q.ki_quest_active)
                ki_a_str = ki_id and tostring(has_ki_active) or 'UNRESOLVED'
            end
            local ki_i_str = 'n/a'
            if q.ki_quest_incomplete and q.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(q.ki_quest_incomplete)
                ki_i_str = ki_id and tostring(has_ki_incomplete) or 'UNRESOLVED'
            end
            dlog(string.format('derive [%s]: %s -> %s (quest_active=%s, ki_active=%s, ki_incomplete=%s, stored=%s)',
                q.name, tostring(last_derived_status[q.name]), result,
                qa_str, ki_a_str, ki_i_str, tostring(stored_status)))
        end
    end

    last_derived_status[q.name] = result
    return result
end

-- ============================================================================
-- KI Removal Detection (called after 0x055 packet updates ki_bitmap)
-- ============================================================================
-- Compares prev_ki_bitmap vs ki_bitmap for each quest's KI fields.
-- ki_quest_incomplete: "has" -> "doesn't have" = turned in -> COMPLETED
-- ki_quest_active:     "has" -> "doesn't have" = objective done -> READY TO TURN IN
local function process_ki_removals(table_index)
    local name = get_current_char_name()
    if not name then return end

    -- Standard quests: ki_quest_incomplete removal = COMPLETED (turned in)
    for _, q in ipairs(QUESTS) do
        if q.type ~= 'enm' and q.ki_quest_incomplete and q.ki_quest_incomplete ~= '' then
            local ki_id = resolve_ki_id(q.ki_quest_incomplete)
            if ki_id then
                local ki_table = math.floor(ki_id / 512)
                if ki_table == table_index then
                    local previously_had = had_key_item(ki_id)
                    local currently_has  = has_key_item(ki_id)

                    if previously_had and not currently_has then
                        log(string.format('KI removed: %s - marking %s as COMPLETED.',
                            q.ki_quest_incomplete, q.name))
                        try_advance(name, q.name, 'COMPLETED')
                    end
                end
            else
                dlog(string.format('process_ki_removals [%s]: %s UNRESOLVED, skipping.',
                    q.name, q.ki_quest_incomplete))
            end
        end
    end

    -- Standard quests: ki_quest_active removal
    -- If ki_active_is_completion = true: KI removal = COMPLETED (no turn-in needed)
    -- Otherwise: KI removal = READY TO TURN IN (objective done, go turn in)
    for _, q in ipairs(QUESTS) do
        if q.type ~= 'enm' and q.ki_quest_active and q.ki_quest_active ~= '' then
            local ki_id = resolve_ki_id(q.ki_quest_active)
            if ki_id then
                local ki_table = math.floor(ki_id / 512)
                if ki_table == table_index then
                    local previously_had = had_key_item(ki_id)
                    local currently_has  = has_key_item(ki_id)

                    if previously_had and not currently_has then
                        if q.ki_active_is_completion then
                            log(string.format('KI removed: %s - marking %s as COMPLETED.',
                                q.ki_quest_active, q.name))
                            try_advance(name, q.name, 'COMPLETED')
                        else
                            log(string.format('KI removed: %s - marking %s as READY TO TURN IN.',
                                q.ki_quest_active, q.name))
                            try_advance(name, q.name, 'READY TO TURN IN')
                        end
                    end
                end
            end
        end
    end

    -- Eco warriors
    local cd = ensure_char(name)
    if cd then
        for _, ew in ipairs(ECO_WARRIORS) do
            if ew.ki_quest_incomplete and ew.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(ew.ki_quest_incomplete)
                if ki_id then
                    local ki_table = math.floor(ki_id / 512)
                    if ki_table == table_index then
                        local previously_had = had_key_item(ki_id)
                        local currently_has  = has_key_item(ki_id)

                        if previously_had and not currently_has then
                            local week = get_week_key()
                            log(string.format('Eco Warrior KI removed: %s - marking %s as completed for %s.',
                                ew.ki_quest_incomplete, ew.nation, week))
                            cd.eco[ew.key].completed_week = week
                            save_data()
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- ImGui Rendering
-- ============================================================================
local STATUS_COLORS = {
    ['NOT STARTED']      = { 0.6, 0.6, 0.6, 1.0 },     -- grey
    ['NEED TO COMPLETE'] = { 1.0, 0.85, 0.0, 1.0 },     -- yellow
    ['READY TO TURN IN'] = { 0.4, 0.8, 1.0, 1.0 },      -- light blue
    ['COMPLETED']        = { 0.0, 1.0, 0.4, 1.0 },       -- green
}

local KI_COLOR_YES = { 0.0, 1.0, 0.4, 1.0 }        -- green
local KI_COLOR_NO  = { 1.0, 0.3, 0.3, 1.0 }        -- red
local KI_COLOR_DIM = { 0.5, 0.5, 0.5, 1.0 }        -- grey


-- Format a unix timestamp as a short date/time string
local function format_time(ts)
    if not ts then return '-' end
    return os.date('%m/%d %H:%M', ts)
end

-- ============================================================================
-- Eco Warrior Status Derivation
-- ============================================================================
-- Determines the display status for each eco warrior nation.
-- Returns a table: { [nation_key] = { status = '...', completed_week = '...' | nil } }
--
-- Logic:
--   1. If this nation is currently flagged (quest active or has KI) -> 'Flagged'
--   2. If this nation was completed THIS week -> 'Completed'
--   3. If another nation is flagged or completed this week -> 'Not Available'
--   4. Round-robin check: a nation is 'Available' only if all nations that were
--      completed MORE RECENTLY have been done. i.e. you must do each nation
--      before repeating one. If this nation was completed more recently than
--      at least one other nation, it's 'Not Available'.
--   5. Otherwise -> 'Available'
--
local function derive_eco_statuses(cd, is_current_char)
    local week = get_week_key()
    local results = {}
    local any_flagged_this_week = false
    local any_completed_this_week = false

    -- First pass: detect flagged and completed-this-week
    for _, ew in ipairs(ECO_WARRIORS) do
        local eco_data = cd.eco and cd.eco[ew.key] or {}
        local flagged = false

        -- Live packet check for current char
        if is_current_char then
            if ew.quest_log_id and ew.quest_id then
                if is_quest_active(ew.quest_log_id, ew.quest_id) then
                    flagged = true
                end
            end
            if ew.ki_quest_incomplete and ew.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(ew.ki_quest_incomplete)
                if ki_id and has_key_item(ki_id) then
                    flagged = true
                end
            end
        end

        local completed_this_week = (eco_data.completed_week == week)

        results[ew.key] = {
            flagged = flagged,
            completed_this_week = completed_this_week,
            completed_week = eco_data.completed_week,
        }

        if flagged then any_flagged_this_week = true end
        if completed_this_week then any_completed_this_week = true end
    end

    -- Second pass: determine display status
    -- Build a sorted list of completion weeks for the round-robin check
    -- A nation is "available" if no other nation has a LESS recent (or nil)
    -- completed_week. i.e. nations with nil or oldest completed_week go first.
    for _, ew in ipairs(ECO_WARRIORS) do
        local r = results[ew.key]

        if r.flagged then
            r.status = 'Flagged'
        elseif r.completed_this_week then
            r.status = 'Completed'
        elseif any_flagged_this_week or any_completed_this_week then
            -- Another nation is active/completed this week
            r.status = 'Not Available'
        else
            -- Round-robin check: this nation is available only if it wasn't
            -- completed more recently than ALL other nations.
            -- A nation with nil completed_week is considered oldest (available first).
            local my_week = r.completed_week  -- may be nil
            local dominated = false
            for _, other_ew in ipairs(ECO_WARRIORS) do
                if other_ew.key ~= ew.key then
                    local other_week = results[other_ew.key].completed_week
                    -- If another nation has never been done (nil) or was done
                    -- in an older week, then that nation should go first, making
                    -- this one not available (unless this one is also nil/older).
                    if other_week == nil and my_week ~= nil then
                        -- Other has never been done but I have -> I'm blocked
                        dominated = true
                        break
                    elseif other_week ~= nil and my_week ~= nil and other_week < my_week then
                        -- Other was done longer ago than me -> they should go first
                        dominated = true
                        break
                    end
                end
            end
            r.status = dominated and 'Not Available' or 'Available'
        end
    end

    return results
end

local ECO_STATUS_COLORS = {
    ['Available']     = { 0.0, 1.0, 0.4, 1.0 },    -- green
    ['Flagged']       = { 1.0, 0.85, 0.0, 1.0 },    -- yellow
    ['Completed']     = { 0.4, 0.8, 1.0, 1.0 },     -- light blue
    ['Not Available'] = { 0.6, 0.6, 0.6, 1.0 },     -- grey
}

-- ENM cooldown status helper
-- Returns: status_text, color, ready_time_text
local function get_enm_status(enm_data, q)
    local cooldown_secs = (q.enm_cooldown_days or 5) * 86400
    local obtained = enm_data and enm_data.ki_obtained_time or nil

    if not obtained then
        return 'READY', KI_COLOR_YES, '-'
    end

    local ready_at = obtained + cooldown_secs
    local now = os.time()
    local ready_str = format_time(ready_at)

    if now >= ready_at then
        return 'READY', KI_COLOR_YES, ready_str
    else
        local remaining = ready_at - now
        local days = math.floor(remaining / 86400)
        local hours = math.floor((remaining % 86400) / 3600)
        local mins = math.floor((remaining % 3600) / 60)
        local countdown = string.format('%dd %dh %dm', days, hours, mins)
        return countdown, STATUS_COLORS['NEED TO COMPLETE'], ready_str
    end
end

local function render_ui()
    if not show_window[1] then return end

    imgui.SetNextWindowSize({ 720, 480 }, ImGuiCond_FirstUseEver)

    if imgui.Begin('Weeklier - Weekly Quest Tracker', show_window, ImGuiWindowFlags_None) then

        -- Current week label + countdown to next reset
        local next_reset = get_next_reset_time()
        local remaining = next_reset - now_utc()
        imgui.Text('Week: ' .. get_week_key())
        imgui.SameLine()
        imgui.Text('   ')
        imgui.SameLine()
        if remaining <= 3600 then
            imgui.TextColored({ 1.0, 0.3, 0.3, 1.0 }, 'Reset in: ' .. format_countdown(remaining))
        elseif remaining <= 86400 then
            imgui.TextColored({ 1.0, 0.85, 0.0, 1.0 }, 'Reset in: ' .. format_countdown(remaining))
        else
            imgui.TextColored({ 0.6, 0.8, 1.0, 1.0 }, 'Reset in: ' .. format_countdown(remaining))
        end
        imgui.Separator()

        -- Collect character names sorted alphabetically, current char first
        -- Filter out the _hidden key which is not a character
        local char_names = {}
        for name, _ in pairs(data) do
            if name ~= '_hidden' then
                char_names[#char_names + 1] = name
            end
        end
        table.sort(char_names, function(a, b)
            if a == current_char then return true end
            if b == current_char then return false end
            return a < b
        end)

        -- Build visible quest lists (excluding hidden)
        local weekly_quests = {}
        local enm_quests = {}
        for _, q in ipairs(QUESTS) do
            if not is_quest_hidden(q.name) then
                if q.type == 'enm' then
                    enm_quests[#enm_quests + 1] = q
                else
                    weekly_quests[#weekly_quests + 1] = q
                end
            end
        end

        if #char_names == 0 then
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'No character data yet. Log in and play!')
        elseif imgui.BeginTabBar('##mainTabs') then

            -- ==========================================================
            -- Character tabs
            -- ==========================================================
            for _, char_name in ipairs(char_names) do
                local cd = data[char_name]
                if cd and imgui.BeginTabItem(char_name) then
                    local is_current_tab = (char_name == current_char)

                    -- ==================================================
                    -- WEEKLY QUESTS SECTION (collapsible)
                    -- ==================================================
                    if #weekly_quests > 0 then
                        if imgui.CollapsingHeader('Weekly Quests', ImGuiTreeNodeFlags_DefaultOpen) then

                            imgui.Columns(3, '##questCols', true)
                            imgui.SetColumnWidth(0, 30)
                            imgui.SetColumnWidth(1, 220)
                            imgui.Text('')
                            imgui.NextColumn()
                            imgui.Text('Quest')
                            imgui.NextColumn()
                            imgui.Text('Status')
                            imgui.NextColumn()
                            imgui.Separator()

                            for _, q in ipairs(weekly_quests) do
                                local stored_status = cd.quests[q.name] or 'NOT STARTED'
                                local status

                                -- For the current character, derive status from live packet data
                                -- and persist it. For other characters, use stored status.
                                if is_current_tab and q.type ~= 'kill_mob' then
                                    status = derive_quest_status(q, stored_status)
                                    -- Persist derived status so it's visible on other chars
                                    if status ~= stored_status then
                                        dlog(string.format('Persisting derived status [%s]: %s -> %s',
                                            q.name, stored_status, status))
                                        cd.quests[q.name] = status
                                        save_data()
                                    end
                                else
                                    status = stored_status
                                end

                                local color = STATUS_COLORS[status] or STATUS_COLORS['NOT STARTED']

                                -- Hide button
                                imgui.PushID('hide_wq_' .. q.name)
                                if imgui.SmallButton('x') then
                                    set_quest_hidden(q.name, true)
                                    save_data()
                                end
                                imgui.PopID()
                                imgui.NextColumn()

                                imgui.Text(q.name)
                                imgui.NextColumn()
                                imgui.TextColored(color, status)
                                imgui.NextColumn()
                            end

                            imgui.Columns(1)
                        end
                    end

                    -- ==================================================
                    -- ECO WARRIORS SECTION (collapsible)
                    -- ==================================================
                    if not is_quest_hidden('Eco Warriors') then
                        imgui.Spacing()
                        if imgui.CollapsingHeader('Eco Warriors', ImGuiTreeNodeFlags_DefaultOpen) then
                            local eco_statuses = derive_eco_statuses(cd, is_current_tab)

                            -- Persist eco status for current char so it's viewable on other chars
                            if is_current_tab then
                                local eco_changed = false
                                for _, ew in ipairs(ECO_WARRIORS) do
                                    local r = eco_statuses[ew.key]
                                    if not cd.eco[ew.key] then cd.eco[ew.key] = {} end
                                    if cd.eco[ew.key].stored_status ~= r.status then
                                        cd.eco[ew.key].stored_status = r.status
                                        eco_changed = true
                                    end
                                end
                                if eco_changed then save_data() end
                            else
                                -- For non-current chars, use stored status if live data unavailable
                                for _, ew in ipairs(ECO_WARRIORS) do
                                    local r = eco_statuses[ew.key]
                                    local stored = cd.eco and cd.eco[ew.key] and cd.eco[ew.key].stored_status
                                    if stored and r.status ~= 'Completed' and not r.flagged then
                                        r.status = stored
                                    end
                                end
                            end

                            imgui.Columns(4, '##ecoCols', true)
                            imgui.SetColumnWidth(0, 30)
                            imgui.SetColumnWidth(1, 140)
                            imgui.SetColumnWidth(2, 120)
                            imgui.Text('')
                            imgui.NextColumn()
                            imgui.Text('Nation')
                            imgui.NextColumn()
                            imgui.Text('Status')
                            imgui.NextColumn()
                            imgui.Text('Last Completed')
                            imgui.NextColumn()
                            imgui.Separator()

                            for _, ew in ipairs(ECO_WARRIORS) do
                                if not is_quest_hidden('Eco_' .. ew.key) then
                                    local r = eco_statuses[ew.key]
                                    local color = ECO_STATUS_COLORS[r.status] or KI_COLOR_DIM

                                    -- Hide button
                                    imgui.PushID('hide_eco_' .. ew.key)
                                    if imgui.SmallButton('x') then
                                        set_quest_hidden('Eco_' .. ew.key, true)
                                        save_data()
                                    end
                                    imgui.PopID()
                                    imgui.NextColumn()

                                    imgui.Text(ew.nation)
                                    imgui.NextColumn()

                                    imgui.TextColored(color, r.status)
                                    imgui.NextColumn()

                                    -- Last completed week
                                    local cw = r.completed_week
                                    if cw then
                                        imgui.Text(cw)
                                    else
                                        imgui.TextColored(KI_COLOR_DIM, 'Never')
                                    end
                                    imgui.NextColumn()
                                end
                            end

                            imgui.Columns(1)
                        end
                    end

                    -- ==================================================
                    -- ENM SECTION (collapsible)
                    -- ==================================================
                    if #enm_quests > 0 then
                        imgui.Spacing()
                        if imgui.CollapsingHeader('ENMs (Cooldown-Based)', ImGuiTreeNodeFlags_DefaultOpen) then

                            imgui.Columns(6, '##enmCols', true)
                            imgui.SetColumnWidth(0, 30)
                            imgui.SetColumnWidth(1, 180)
                            imgui.SetColumnWidth(2, 70)
                            imgui.SetColumnWidth(3, 100)
                            imgui.SetColumnWidth(4, 100)
                            imgui.Text('')
                            imgui.NextColumn()
                            imgui.Text('ENM')
                            imgui.NextColumn()
                            imgui.Text('Has KI')
                            imgui.NextColumn()
                            imgui.Text('Obtained')
                            imgui.NextColumn()
                            imgui.Text('Ready At')
                            imgui.NextColumn()
                            imgui.Text('Status')
                            imgui.NextColumn()
                            imgui.Separator()

                            for _, q in ipairs(enm_quests) do
                                local enm_data = cd.enms and cd.enms[q.name] or {}

                                -- Hide button
                                imgui.PushID('hide_enm_' .. q.name)
                                if imgui.SmallButton('x') then
                                    set_quest_hidden(q.name, true)
                                    save_data()
                                end
                                imgui.PopID()
                                imgui.NextColumn()

                                -- ENM Name
                                imgui.Text(q.name)
                                imgui.NextColumn()

                                -- Has KI (live packet data for current char, stored for others)
                                if is_current_tab then
                                    if q.ki_quest_active and q.ki_quest_active ~= '' then
                                        local ki_id = resolve_ki_id(q.ki_quest_active)
                                        if ki_id then
                                            if has_key_item(ki_id) then
                                                imgui.TextColored(KI_COLOR_YES, 'Yes')
                                            else
                                                imgui.TextColored(KI_COLOR_NO, 'No')
                                            end
                                        else
                                            imgui.TextColored(KI_COLOR_DIM, '??')
                                        end
                                    else
                                        imgui.Text('-')
                                    end
                                else
                                    -- Use stored has_ki from JSON
                                    local stored_ki = enm_data.has_ki
                                    if stored_ki == true then
                                        imgui.TextColored(KI_COLOR_YES, 'Yes')
                                    elseif stored_ki == false then
                                        imgui.TextColored(KI_COLOR_NO, 'No')
                                    else
                                        imgui.TextColored(KI_COLOR_DIM, '??')
                                    end
                                end
                                imgui.NextColumn()

                                -- Obtained timestamp
                                local obtained_ts = enm_data.ki_obtained_time
                                imgui.Text(format_time(obtained_ts))
                                imgui.NextColumn()

                                -- Ready At / Status
                                local status_text, status_color, ready_str = get_enm_status(enm_data, q)
                                imgui.Text(ready_str)
                                imgui.NextColumn()
                                imgui.TextColored(status_color, status_text)
                                imgui.NextColumn()
                            end

                            imgui.Columns(1)
                        end
                    end

                    imgui.EndTabItem()
                end
            end

            -- ==========================================================
            -- Config tab
            -- ==========================================================
            if imgui.BeginTabItem('Config') then

                -- ----------------------------------------------------------
                -- Hidden Quests
                -- ----------------------------------------------------------
                imgui.TextColored({ 1.0, 1.0, 0.6, 1.0 }, 'Hidden Quests')
                imgui.Separator()
                imgui.TextWrapped('Quests hidden from the tracker. Click Show to restore them.')
                imgui.Spacing()

                local any_hidden = false

                -- Eco Warriors section header
                if is_quest_hidden('Eco Warriors') then
                    any_hidden = true
                    imgui.PushID('show_eco_section')
                    if imgui.SmallButton('Show') then
                        set_quest_hidden('Eco Warriors', false)
                        save_data()
                    end
                    imgui.PopID()
                    imgui.SameLine()
                    imgui.Text('[Eco] Eco Warriors (entire section)')
                end

                -- Individual eco nations
                for _, ew in ipairs(ECO_WARRIORS) do
                    local hide_key = 'Eco_' .. ew.key
                    if is_quest_hidden(hide_key) then
                        any_hidden = true
                        imgui.PushID('show_' .. hide_key)
                        if imgui.SmallButton('Show') then
                            set_quest_hidden(hide_key, false)
                            save_data()
                        end
                        imgui.PopID()
                        imgui.SameLine()
                        imgui.Text(string.format('[Eco] %s', ew.nation))
                    end
                end

                -- Regular quests
                for _, q in ipairs(QUESTS) do
                    if is_quest_hidden(q.name) then
                        any_hidden = true
                        local type_label = q.type == 'enm' and 'ENM' or (q.type == 'kill_mob' and 'Kill' or 'Quest')
                        imgui.PushID('show_' .. q.name)
                        if imgui.SmallButton('Show') then
                            set_quest_hidden(q.name, false)
                            save_data()
                        end
                        imgui.PopID()
                        imgui.SameLine()
                        imgui.Text(string.format('[%s] %s', type_label, q.name))
                    end
                end

                if not any_hidden then
                    imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, 'No hidden quests.')
                end

                -- ----------------------------------------------------------
                -- Eco Warrior Manual Override
                -- ----------------------------------------------------------
                imgui.Spacing()
                imgui.Spacing()
                imgui.TextColored({ 1.0, 0.6, 0.4, 1.0 }, 'Eco Warrior - Manual Override')
                imgui.Separator()
                imgui.TextWrapped('Mark a nation as completed for a specific week to bootstrap the round-robin cycle. Select the character, then click a button to mark that nation as completed for the current week (or click Clear to remove the completion record).')
                imgui.Spacing()

                -- Character selector for eco override
                local char_names_eco = {}
                for cname, cdata in pairs(data) do
                    if cname ~= '_hidden' and type(cdata) == 'table' and cdata.quests then
                        char_names_eco[#char_names_eco + 1] = cname
                    end
                end
                table.sort(char_names_eco)

                for _, cname in ipairs(char_names_eco) do
                    local cd = data[cname]
                    if cd then
                        imgui.Text(cname .. ':')
                        imgui.SameLine()
                        for _, ew in ipairs(ECO_WARRIORS) do
                            local eco_data = cd.eco and cd.eco[ew.key] or {}
                            local cw = eco_data.completed_week
                            local week = get_week_key()

                            imgui.PushID('eco_override_' .. cname .. '_' .. ew.key)
                            if cw == week then
                                -- Already marked this week - show clear button
                                imgui.TextColored(ECO_STATUS_COLORS['Completed'], ew.nation)
                                imgui.SameLine()
                                if imgui.SmallButton('Clear') then
                                    cd.eco[ew.key].completed_week = nil
                                    save_data()
                                    log(string.format('Eco override: cleared %s for %s', ew.nation, cname))
                                end
                            else
                                -- Show mark button
                                if imgui.SmallButton(ew.nation) then
                                    if not cd.eco then cd.eco = {} end
                                    if not cd.eco[ew.key] then cd.eco[ew.key] = {} end
                                    cd.eco[ew.key].completed_week = week
                                    save_data()
                                    log(string.format('Eco override: marked %s as completed %s for %s',
                                        ew.nation, week, cname))
                                end
                            end
                            imgui.PopID()
                            imgui.SameLine()
                        end
                        -- Show current completed weeks
                        imgui.Text('')  -- newline after SameLine chain
                        imgui.SameLine()
                        local parts = {}
                        for _, ew in ipairs(ECO_WARRIORS) do
                            local eco_data = cd.eco and cd.eco[ew.key] or {}
                            local cw = eco_data.completed_week or 'Never'
                            parts[#parts + 1] = string.format('%s=%s', ew.key, cw)
                        end
                        imgui.TextColored(KI_COLOR_DIM, '  (' .. table.concat(parts, ', ') .. ')')
                    end
                end

                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end
    end
    imgui.End()
end

-- ============================================================================
-- Events
-- ============================================================================
ashita.events.register('load', 'weeklier_load_cb', function()
    save_path = string.format('%s/char_data.json', addon.path)
    build_ki_lookup()
    load_data()
    log('Loaded. Use /weeklier show to open the tracker.')
end)

ashita.events.register('unload', 'weeklier_unload_cb', function()
    save_data()
    log('Data saved. Unloaded.')
end)

-- ============================================================================
-- Commands
-- ============================================================================
ashita.events.register('command', 'weeklier_command_cb', function(e)
    local args = e.command:args()
    if not args or #args == 0 then return end
    if args[1]:lower() ~= '/weeklier' then return end

    e.blocked = true

    local sub = args[2] and args[2]:lower() or 'show'

    if sub == 'show' or sub == 'toggle' then
        show_window[1] = not show_window[1]
        return
    end

    if sub == 'hide' then
        show_window[1] = false
        return
    end

    if sub == 'reset' then
        -- Reset current character's quest data for this week
        local name = get_current_char_name()
        if name then
            local cd = ensure_char(name)
            if cd then
                for _, q in ipairs(QUESTS) do
                    if q.type ~= 'enm' then
                        if q.type == 'kill_mob' then
                            cd.quests[q.name] = 'NEED TO COMPLETE'
                        else
                            cd.quests[q.name] = 'NOT STARTED'
                        end
                    end
                end
                save_data()
                log('Reset all quests for ' .. name)
            end
        else
            log('Cannot determine current character.')
        end
        return
    end

    if sub == 'resetall' then
        data = {}
        hidden_quests = {}
        data._hidden = hidden_quests
        save_data()
        log('All character data cleared.')
        return
    end

    if sub == 'status' then
        local name = get_current_char_name()
        if name then
            local cd = ensure_char(name)
            if cd then
                log('Quest status for ' .. name .. ' (' .. cd.week .. '):')
                for _, q in ipairs(QUESTS) do
                    log(string.format('  %s: %s', q.name, cd.quests[q.name] or 'NOT STARTED'))
                end
                -- Eco warriors
                local eco_statuses = derive_eco_statuses(cd, true)
                for _, ew in ipairs(ECO_WARRIORS) do
                    local r = eco_statuses[ew.key]
                    local cw = r.completed_week or 'Never'
                    log(string.format('  [Eco] %s: %s (last=%s)', ew.nation, r.status, cw))
                end
            end
        else
            log('Cannot determine current character.')
        end
        return
    end

    if sub == 'help' then
        log('Commands:')
        log('  /weeklier show    - toggle the tracker window')
        log('  /weeklier hide    - close the tracker window')
        log('  /weeklier status  - print quest status to chat')
        log('  /weeklier reset   - reset current character\'s quests')
        log('  /weeklier resetall- clear ALL character data')
        log('  /weeklier debug   - toggle debug logging')
        log('  /weeklier dump    - dump current packet state for diagnostics')
        log('  /weeklier help    - show this help')
        return
    end

    if sub == 'debug' then
        debug_mode = not debug_mode
        log('Debug mode: ' .. (debug_mode and 'ON' or 'OFF'))
        return
    end

    if sub == 'dump' then
        local char = get_current_char_name() or '(unknown)'
        log('--- Weeklier State Dump ---')
        log('Current char: ' .. char)
        log('Week key: ' .. get_week_key())
        log('Debug mode: ' .. (debug_mode and 'ON' or 'OFF'))

        -- KI bitmap loaded tables
        local ki_tables = {}
        for idx, _ in pairs(ki_bitmap) do ki_tables[#ki_tables + 1] = tostring(idx) end
        table.sort(ki_tables)
        log('KI bitmap tables loaded: [' .. table.concat(ki_tables, ', ') .. ']')

        -- Quest blocks loaded
        local qb_tables = {}
        for idx, _ in pairs(active_quest_blocks) do qb_tables[#qb_tables + 1] = tostring(idx) end
        table.sort(qb_tables)
        log('Quest blocks loaded (log_ids): [' .. table.concat(qb_tables, ', ') .. ']')

        -- Per-quest diagnostics
        for _, q in ipairs(QUESTS) do
            if q.type == 'enm' then
                local ki_id = resolve_ki_id(q.ki_quest_active)
                local has = ki_id and has_key_item(ki_id) or false
                log(string.format('  [ENM] %s: ki=%s (id=%s) has=%s',
                    q.name, tostring(q.ki_quest_active), tostring(ki_id), tostring(has)))
            elseif q.type == 'kill_mob' then
                local cd = data[char] and data[char].quests or {}
                log(string.format('  [KILL] %s: stored=%s',
                    q.name, tostring(cd[q.name])))
            else
                local cd = data[char] and data[char].quests or {}
                local stored = cd[q.name] or 'NOT STARTED'
                local qa = (q.quest_log_id and q.quest_id) and is_quest_active(q.quest_log_id, q.quest_id) or false
                local ki_a_id = resolve_ki_id(q.ki_quest_active)
                local ki_i_id = resolve_ki_id(q.ki_quest_incomplete)
                local has_a = ki_a_id and has_key_item(ki_a_id) or false
                local has_i = ki_i_id and has_key_item(ki_i_id) or false
                log(string.format('  [QUEST] %s: stored=%s quest_active=%s ki_active=%s(id=%s,has=%s) ki_incomplete=%s(id=%s,has=%s)',
                    q.name, stored, tostring(qa),
                    tostring(q.ki_quest_active), tostring(ki_a_id), tostring(has_a),
                    tostring(q.ki_quest_incomplete), tostring(ki_i_id), tostring(has_i)))
            end
        end

        -- Eco warrior diagnostics
        local cd_eco = data[char] and data[char].eco or {}
        for _, ew in ipairs(ECO_WARRIORS) do
            local eco_data = cd_eco[ew.key] or {}
            local qa = is_quest_active(ew.quest_log_id, ew.quest_id)
            local ki_id = resolve_ki_id(ew.ki_quest_incomplete)
            local has_ki = ki_id and has_key_item(ki_id) or false
            log(string.format('  [ECO] %s: completed_week=%s quest_active=%s ki=%s(id=%s,has=%s)',
                ew.nation, tostring(eco_data.completed_week), tostring(qa),
                tostring(ew.ki_quest_incomplete), tostring(ki_id), tostring(has_ki)))
        end

        log('--- End Dump ---')
        return
    end

    log('Unknown command. Try /weeklier help')
end)

-- ============================================================================
-- Chat Monitoring
-- ============================================================================
ashita.events.register('text_in', 'weeklier_text_in_cb', function(e)
    if e.injected then return end
    if not e.message or e.message == '' then return end

    -- Identify the current character
    local name = get_current_char_name()
    if not name then return end

    -- Keep current_char up to date for UI sorting
    if current_char ~= name then
        current_char = name
        ensure_char(name)
    end

    local msg = normalize_string(e.message)
    if not msg then return end
    local now = os.clock()

    -- ------------------------------------------------------------------
    -- Phase 2 of kill detection: look for XP gain from this character.
    -- Must come BEFORE we check for new "defeats" lines so that a single
    -- text_in pass can't latch + confirm on the same frame.
    -- Pattern: "<charname> gains 1234 experience points."
    -- ------------------------------------------------------------------
    if next(pending_kills) then
        local xp_pattern = normalize_string(name) .. ' gains %d+ experience points'
        if string.find(msg, xp_pattern) then
            dlog(string.format('XP message matched: "%s"', msg))
            -- Confirm every pending kill that is still within the window
            for qi, ts in pairs(pending_kills) do
                if (now - ts) <= KILL_CONFIRM_WINDOW then
                    local q = QUESTS[qi]
                    if q then
                        try_advance(name, q.name, 'COMPLETED')
                        log(string.format('Kill confirmed: %s (XP received)', q.name))
                    end
                else
                    dlog(string.format('Kill expired: quest[%d] age=%.1fs > window=%.1fs',
                        qi, now - ts, KILL_CONFIRM_WINDOW))
                end
            end
            -- Clear all pending kills once XP is confirmed
            pending_kills = {}
        end

        -- Expire any stale pending kills outside the window
        for qi, ts in pairs(pending_kills) do
            if (now - ts) > KILL_CONFIRM_WINDOW then
                pending_kills[qi] = nil
            end
        end
    end

    -- ------------------------------------------------------------------
    -- Check every quest definition
    -- ------------------------------------------------------------------
    for qi, q in ipairs(QUESTS) do

        -- ==============================================================
        -- Flag phrase detection (chat-based alternative to quest_log_id)
        -- ==============================================================
        if q.flag_phrase and q.flag_phrase ~= '' and q.type ~= 'enm' and q.type ~= 'kill_mob' then
            local phrase = normalize_string(q.flag_phrase)
            if phrase and string.find(msg, phrase, 1, true) then
                try_advance(name, q.name, 'NEED TO COMPLETE')
                dlog(string.format('Flag phrase matched [%s]: "%s"', q.name, q.flag_phrase))
            end
        end

        -- ==============================================================
        -- Complete phrase detection (chat-based turn-in confirmation)
        -- ==============================================================
        if q.complete_phrase and q.complete_phrase ~= '' and q.type ~= 'enm' and q.type ~= 'kill_mob' then
            local phrase = normalize_string(q.complete_phrase)
            if phrase and string.find(msg, phrase, 1, true) then
                try_advance(name, q.name, 'COMPLETED')
                dlog(string.format('Complete phrase matched [%s]: "%s"', q.name, q.complete_phrase))
            end
        end

        -- ==============================================================
        -- ENM quest: detect "Obtained key item: <ki_display_name>."
        -- ==============================================================
        if q.type == 'enm' and q.ki_display_name and q.ki_display_name ~= '' then
            local ki_phrase = 'obtained key item: ' .. normalize_string(q.ki_display_name)
            if string.find(msg, ki_phrase, 1, true) then
                local cd = ensure_char(name)
                if cd then
                    if not cd.enms then cd.enms = {} end
                    if not cd.enms[q.name] then cd.enms[q.name] = {} end
                    cd.enms[q.name].ki_obtained_time = os.time()
                    local cooldown = q.enm_cooldown_days or 5
                    log(string.format('ENM KI obtained: %s - %d day cooldown started.', q.name, cooldown))
                    save_data()
                end
            end
        end

        -- ==============================================================
        -- Kill-mob quest: phase 1 - look for "defeats the <mob>"
        -- ==============================================================
        if q.type == 'kill_mob' and q.kill_mob and q.kill_mob ~= '' then
            local defeat_phrase = 'defeats the ' .. normalize_string(q.kill_mob)
            if string.find(msg, defeat_phrase, 1, true) then
                pending_kills[qi] = now
                log(string.format('Mob defeated: %s - waiting for XP confirm...', q.kill_mob))
            end
        end
    end
end)

-- ============================================================================
-- Key Item Packet (0x055) - updates ki_bitmap
-- ============================================================================
-- Packet layout (GP_SERV_SCENARIOITEM):
--   0x00  header (4 bytes: id/size/sync)
--   0x04  GetItemFlag[16]  - 16 x uint32 = 64 bytes (obtained KI bits)
--   0x44  LookItemFlag[16] - 16 x uint32 = 64 bytes (viewed KI bits)
--   0x84  TableIndex       - uint16 (0-6, which 512-KI block)
--   0x86  padding
-- All offsets are 0-based; Lua string.byte is 1-based, so +1.
-- ============================================================================
ashita.events.register('packet_in', 'weeklier_packet_in_cb', function(e)
    if e.id ~= 0x055 then return end

    -- Clear stale packet state if the character has changed since last packet
    check_packet_char_change()

    local pkt = e.data
    if not pkt or #pkt < 0x88 then return end

    -- TableIndex is at offset 0x84 (uint16 LE) -> 1-based offset 0x85
    local table_index = u16le(pkt, 0x84 + 1)
    if table_index < 0 or table_index > 6 then return end

    -- Snapshot the previous bitmap for this table before overwriting
    if ki_bitmap[table_index] then
        local prev = {}
        for i = 0, 15 do
            prev[i] = ki_bitmap[table_index][i] or 0
        end
        prev_ki_bitmap[table_index] = prev
    end

    -- GetItemFlag starts at offset 0x04 -> 1-based offset 0x05
    local tbl = {}
    for i = 0, 15 do
        tbl[i] = u32le(pkt, 0x04 + 1 + (i * 4))
    end
    ki_bitmap[table_index] = tbl

    -- Debug: log KI status for every configured quest whose KI lives in this table
    if debug_mode then
        for _, q in ipairs(QUESTS) do
            -- Check ki_quest_active
            if q.ki_quest_active and q.ki_quest_active ~= '' then
                local ki_id = resolve_ki_id(q.ki_quest_active)
                if ki_id and math.floor(ki_id / 512) == table_index then
                    dlog(string.format('0x055 [%s]: ki_quest_active=%s (id=%d) has=%s',
                        q.name, q.ki_quest_active, ki_id, tostring(has_key_item(ki_id))))
                end
            end
            -- Check ki_quest_incomplete
            if q.ki_quest_incomplete and q.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(q.ki_quest_incomplete)
                if ki_id and math.floor(ki_id / 512) == table_index then
                    local prev_had = had_key_item(ki_id)
                    local now_has = has_key_item(ki_id)
                    dlog(string.format('0x055 [%s]: ki_quest_incomplete=%s (id=%d) prev=%s now=%s',
                        q.name, q.ki_quest_incomplete, ki_id, tostring(prev_had), tostring(now_has)))
                end
            end
        end
        -- Eco warriors
        for _, ew in ipairs(ECO_WARRIORS) do
            if ew.ki_quest_incomplete and ew.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(ew.ki_quest_incomplete)
                if ki_id and math.floor(ki_id / 512) == table_index then
                    local prev_had = had_key_item(ki_id)
                    local now_has = has_key_item(ki_id)
                    dlog(string.format('0x055 [Eco %s]: ki=%s (id=%d) prev=%s now=%s',
                        ew.nation, ew.ki_quest_incomplete, ki_id, tostring(prev_had), tostring(now_has)))
                end
            end
        end
    end

    -- Persist ENM KI possession state so it's viewable on other characters
    local char_name = get_current_char_name()
    if char_name then
        local cd = ensure_char(char_name)
        if cd then
            local changed = false
            for _, q in ipairs(QUESTS) do
                if q.type == 'enm' and q.ki_quest_active and q.ki_quest_active ~= '' then
                    local ki_id = resolve_ki_id(q.ki_quest_active)
                    if ki_id and math.floor(ki_id / 512) == table_index then
                        local has = has_key_item(ki_id)
                        if not cd.enms[q.name] then cd.enms[q.name] = {} end
                        if cd.enms[q.name].has_ki ~= has then
                            cd.enms[q.name].has_ki = has
                            changed = true
                            dlog(string.format('ENM KI persisted [%s]: has_ki=%s', q.name, tostring(has)))
                        end
                    end
                end
            end
            if changed then save_data() end
        end
    end

    -- Detect KI removals (ki_quest_incomplete -> COMPLETED, ki_quest_active -> READY TO TURN IN or COMPLETED)
    if prev_ki_bitmap[table_index] then
        process_ki_removals(table_index)
    end
end)

ashita.events.register('packet_in', 'weeklier_packet_in_cb_056_active_quests', function(e)
    if e.id ~= 0x056 then
        return
    end

    -- Clear stale packet state if the character has changed since last packet
    check_packet_char_change()

    local pkt = e.data
    if not pkt or #pkt < 0x28 then
        return
    end

    -- Port at offset 0x24 (uint16 LE)
    local port = u16le(pkt, 0x24 + 1)
    local log_id = QUEST_OFFER_PORT_TO_LOG_ID[port]
    if log_id == nil then
        return
    end

    active_quest_blocks[log_id] = read_u32x8(pkt)

    -- Debug: log quest active status for every configured quest in this log_id
    if debug_mode then
        for _, q in ipairs(QUESTS) do
            if q.quest_log_id and q.quest_log_id == log_id and q.quest_id then
                local active = is_quest_active(q.quest_log_id, q.quest_id)
                dlog(string.format('0x056 [%s]: log_id=%d quest_id=%d active=%s',
                    q.name, q.quest_log_id, q.quest_id, tostring(active)))
            end
        end
        -- Eco warriors
        for _, ew in ipairs(ECO_WARRIORS) do
            if ew.quest_log_id == log_id and ew.quest_id then
                local active = is_quest_active(ew.quest_log_id, ew.quest_id)
                dlog(string.format('0x056 [Eco %s]: log_id=%d quest_id=%d active=%s',
                    ew.nation, ew.quest_log_id, ew.quest_id, tostring(active)))
            end
        end
    end
end)

-- ============================================================================
-- ImGui Render Hook
-- ============================================================================
ashita.events.register('d3d_present', 'weeklier_present_cb', function()
    -- Keep current char name fresh
    local name = get_current_char_name()
    if name and name ~= '' then
        if current_char ~= name then
            current_char = name
            ensure_char(name)
        end
    end

    render_ui()
end)







