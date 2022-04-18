local socket = require("socket")

-- These constants are based on my setup. Yours may differ
-- BUTTON_AXIS_NUMBERS_BEGIN
local PARKING_BRAKE_AXIS_NO = 0

local AP_BTN_HDG = 0
local AP_BTN_NAV = 1
local AP_BTN_APR = 2
local AP_BTN_REV = 3
local AP_BTN_ALT = 4
local AP_BTN_VS  = 5
local AP_BTN_IAS = 6
local AP_BTN_AP  = 7
-- BUTTON_AXIS_NUMBERS_END

local prop_down_start = {0, 0, 0}
local prop_up_start = {0, 0, 0}
local last_parking_brake_action = "set"

local fmc_entry_mode = false -- are we typing into the FMC?
local selected_fmc = 1

local LONG_PRESS_THRESHOLD = 500 -- milliseconds

local btn_alt_time_down = 0 -- used to simulate the ALT-SEL button
local btn_alt_fired = false
local btn_vs_time_down = 0 -- used to simulate the VNAV button
local btn_vs_fired = false
local btn_ap_time_down = 0 -- used to simulate the STBY button
local btn_ap_fired = false

local msg_text = ""
local msg_shown_at = 0
local msg_visible_time = 0

ap_lights_table = create_dataref_table("Q4XP_Helper/ap_lights", "IntArray")
local ap_blink_speed = 500 -- milliseconds, how fast autopilot LEDs should blink when their mode is armed, but not active
local ap_blinking = {0,0,0,0,0,0,0} -- is this LED blinking, and how fast? (0 == not blinking, 1 = normal spd, 2 = 2x spd, etc...)
local ap_blink_timer = {0,0,0,0,0,0,0} -- when did this last change blink state

-- -- roll_act
local HDG_HOLD    = 2
local WING_LVL    = 3
local HDG_SEL     = 4
local LOC_STAR    = 8
local LOC         = 9
local LOC_BC_STAR = 13
local LOC_BC      = 14
local LNAV        = 17

-- -- pitch_act
local PITCH_HOLD = 1
local IAS        = 2
local VS         = 3
local ALT_STAR   = 4
local ALT        = 5
local GA         = 6
local GS_STAR    = 7
local GS         = 8
local VNAV_PATH  = 11

-- alt_arm
local ALT_SEL = 1

-- roll_arm
local LOC_ARM    = 2
local LOC_BC_ARM = 4

-- pitch_arm
local GS_ARM   = 2
local VNAV_ARM = 3

dataref("q4xp_hh_pb_axis", "sim/joystick/joystick_axis_values", "readonly", PARKING_BRAKE_AXIS_NO)
dataref("q4xp_hh_pb_state", "sim/cockpit2/controls/parking_brake_ratio", "writable")

dataref("q4xp_hh_roll_act", "FJS/Q4XP/FMA/roll_act", "readonly")
dataref("q4xp_hh_roll_arm", "FJS/Q4XP/FMA/roll_arm", "readonly")
dataref("q4xp_hh_pitch_act", "FJS/Q4XP/FMA/pitch_act", "readonly")
dataref("q4xp_hh_pitch_arm", "FJS/Q4XP/FMA/pitch_arm", "readonly")
dataref("q4xp_hh_alt_arm", "FJS/Q4XP/FMA/alt_arm", "readonly")
dataref("q4xp_hh_ap_enable", "sim/cockpit/autopilot/autopilot_mode", "readonly")

function q4xp_hh_begin_prop(dir, prop_number)
    local now = now_ms()

    if dir == "down" then
        prop_down_start[prop_number] = now
        command_begin("sim/engines/prop_down_" .. prop_number)
    else
        prop_up_start[prop_number] = now
        command_begin("sim/engines/prop_up_" .. prop_number)
    end
end

function q4xp_hh_end_prop(dir, prop_number)
    if dir == "down" then
        prop_down_start[prop_number] = 0
        command_end("sim/engines/prop_down_" .. prop_number)
    else
        prop_up_start[prop_number] = 0
        command_end("sim/engines/prop_up_" .. prop_number)
    end
end

function q4xp_hh_update_props()
    local now = now_ms()
    for prop=1,2 do
        if prop_down_start[prop] > 0 and (now - prop_down_start[prop]) >= 1000 then
            q4xp_hh_end_prop("down", prop)
        end
        if prop_up_start[prop] > 0 and (now - prop_up_start[prop]) >= 1000 then
            q4xp_hh_end_prop("up", prop)
        end
    end
end

function q4xp_hh_update_parking_brake()
    local want_on = q4xp_hh_pb_axis <= 0.05
    local want_off = q4xp_hh_pb_axis >= 0.95

    local is_on = q4xp_hh_pb_state >= 0.95 -- it takes a bit of time to go from 0.99 to 1

    if (want_on and not is_on) or (want_off and is_on) then
        command_once("sim/flight_controls/brakes_toggle_max")
    end
end

function q4xp_hh_fmc_typer()
    if KEY_ACTION == "pressed" then
        if not fmc_entry_mode and CONTROL_KEY and VKEY == 112 then -- CTRL+F1 for FMC1
            fmc_entry_mode = true
            selected_fmc = 1
            RESUME_KEY = true
        elseif not fmc_entry_mode and CONTROL_KEY and VKEY == 113 then -- CTRL+F2 for FMC2
            fmc_entry_mode = true
            selected_fmc = 2
            RESUME_KEY = true
        elseif fmc_entry_mode and CONTROL_KEY and VKEY == 81 then -- CTRL+Q to leave entry mode
            fmc_entry_mode = false
            RESUME_KEY = true
        elseif fmc_entry_mode then
            if not SHIFT_KEY and VKEY >= 65 and VKEY <= 90 then -- a-z
                command_once("FJS/Q4XP/fms" .. selected_fmc .. "/key_" .. string.upper(CKEY))
            elseif VKEY >= 96 and VKEY <= 105 then -- Numpad 0-9
                command_once("FJS/Q4XP/fms" .. selected_fmc .. "/key_" .. CKEY)
            elseif VKEY >= 49 and VKEY <= 53 then -- number row 1-5
                local side = "l"
                if SHIFT_KEY then side = "r" end
                command_once("FJS/Q4XP/fms" .. selected_fmc .. "/lsk_" .. side .. (VKEY - 48))
            elseif SHIFT_KEY and VKEY >= 65 and VKEY <= 90 then -- F1-F12
                if VKEY == 81 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/data")      -- SHIFT+Q
                elseif VKEY == 87 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/nav")   -- SHIFT+W
                elseif VKEY == 69 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/vnav")  -- SHIFT+E
                elseif VKEY == 82 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/dto")   -- SHIFT+R
                elseif VKEY == 84 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/list")  -- SHIFT+T
                elseif VKEY == 89 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/prev")  -- SHIFT+Y
                elseif VKEY == 65 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/fuel")  -- SHIFT+A
                elseif VKEY == 83 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/fpl")   -- SHIFT+S
                elseif VKEY == 68 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/perf")  -- SHIFT+D
                elseif VKEY == 70 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/tune")  -- SHIFT+F
                elseif VKEY == 71 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/menu")  -- SHIFT+G
                elseif VKEY == 72 then command_once("FJS/Q4XP/fms" .. selected_fmc .. "/next")  -- SHIFT+H
                end
            elseif VKEY == 13 then -- enter
                command_once("FJS/Q4XP/fms" .. selected_fmc .. "/key_enter")
            elseif VKEY == 8 then -- backspace
                command_once("FJS/Q4XP/fms" .. selected_fmc .. "/key_back")
            elseif VKEY == 2 then -- menu key
                command_once("FJS/Q4XP/fms" .. selected_fmc .. "/msg")
            elseif VKEY == 107 then -- numpad + key
                command_once("FJS/Q4XP/fms" .. selected_fmc .. "/plus_minus")
            elseif VKEY == 111 then -- numpad / key
                command_once("FJS/Q4XP/fms" .. selected_fmc .. "/pwr")
            end
            RESUME_KEY = true
        end
    end
end

function q4xp_hh_advise_fmc_typer()
    local warning_string = "ENTERING FMS" .. selected_fmc .. " DATA - CTRL+Q TO EXIT"

    if fmc_entry_mode then
        glColor4f(0, 0, 0, 255)
        draw_string_Helvetica_18(50 - 1, SCREEN_HEIGHT - 130 - 1, warning_string)
        draw_string_Helvetica_18(50 + 1, SCREEN_HEIGHT - 130 + 1, warning_string)
        draw_string_Helvetica_18(50 + 1, SCREEN_HEIGHT - 130 - 1, warning_string)
        draw_string_Helvetica_18(50 - 1, SCREEN_HEIGHT - 130 + 1, warning_string)
        glColor4f(1, 1, 1, 255)
        draw_string_Helvetica_18(50, SCREEN_HEIGHT - 130, warning_string)
    end
end

function q4xp_hh_update_solid_state()
    local btn_hdg_state = (q4xp_hh_roll_act == HDG_SEL) and "on" or "off"
    local btn_nav_state = (q4xp_hh_roll_act == LNAV) and "on" or "off"
    local btn_apr_state = (q4xp_hh_roll_act == LOC_STAR or q4xp_hh_roll_act == LOC) and "on" or "off"
    local btn_rev_state = (q4xp_hh_roll_act == LOC_BC_STAR or q4xp_hh_roll_act == LOC_BC) and "on" or "off"
    local btn_alt_state = (q4xp_hh_pitch_act == ALT) and "on" or "off"
    local btn_vs_state  = (q4xp_hh_pitch_act == VS or q4xp_hh_pitch_act == VNAV) and "on" or "off"
    local btn_ias_state = (q4xp_hh_pitch_act == IAS) and "on" or "off"

    btn_set(AP_BTN_HDG, btn_hdg_state)
    btn_set(AP_BTN_NAV, btn_nav_state)
    btn_set(AP_BTN_APR, btn_apr_state)
    btn_set(AP_BTN_REV, btn_rev_state)
    btn_set(AP_BTN_ALT, btn_alt_state)
    btn_set(AP_BTN_VS, btn_vs_state)
    btn_set(AP_BTN_IAS, btn_ias_state)
end

function q4xp_hh_update_blink_state()
    local btn_hdg_state = false and "blink" or btn_get(AP_BTN_HDG)
    local btn_nav_state = false and "blink" or btn_get(AP_BTN_NAV)
    local btn_apr_state = (q4xp_hh_roll_arm == LOC_ARM and q4xp_hh_pitch_arm == GS_ARM) and "blink" or btn_get(AP_BTN_APR)
    btn_apr_state       = xor(q4xp_hh_roll_arm == LOC_ARM, q4xp_hh_pitch_arm == GS_ARM) and "fast" or btn_apr_state
    local btn_rev_state = (q4xp_hh_roll_arm == LOC_BC_ARM) and "blink" or btn_get(AP_BTN_REV)
    local btn_alt_state = (q4xp_hh_alt_arm == ALT_SEL) and "blink" or btn_get(AP_BTN_ALT)
    btn_alt_state       = (q4xp_hh_alt_arm == 0 and q4xp_hh_pitch_act == ALT_STAR) and "fast" or btn_alt_state
    -- TODO: can we tell when we're within 1k ft of target?
    local btn_vs_state  = (q4xp_hh_pitch_arm == VNAV_ARM) and "blink" or btn_get(AP_BTN_VS)
    local btn_ias_state = false and "blink" or btn_get(AP_BTN_IAS)

    btn_set(AP_BTN_HDG, btn_hdg_state)
    btn_set(AP_BTN_NAV, btn_nav_state)
    btn_set(AP_BTN_APR, btn_apr_state)
    btn_set(AP_BTN_REV, btn_rev_state)
    btn_set(AP_BTN_ALT, btn_alt_state)
    btn_set(AP_BTN_VS, btn_vs_state)
    btn_set(AP_BTN_IAS, btn_ias_state)
end

function q4xp_hh_update_ap_leds()
    local now = now_ms()
    local ap_enable = q4xp_hh_ap_enable > 0

    q4xp_hh_update_solid_state()
    q4xp_hh_update_blink_state()

    for i=0,6 do
        if not ap_enable then
            ap_lights_table[i] = 0
        elseif ap_blinking[i] < 0 then
            ap_lights_table[i] = 1
        elseif ap_blinking[i] == 0 then
            ap_lights_table[i] = 0
        else
            local blink_duration = ap_blink_speed / ap_blinking[i] -- in ms
            if now - ap_blink_timer[i] >= blink_duration then
                if ap_lights_table[i] == 0 then ap_lights_table[i] = 1 else ap_lights_table[i] = 0 end
                ap_blink_timer[i] = now
            end
        end
    end
end

function q4xp_hh_simulate_missing_buttons()
    local now = now_ms()

    if button(AP_BTN_ALT) then
        if btn_alt_time_down == 0 then
            btn_alt_time_down = now
            btn_alt_fired = false
        elseif now - btn_alt_time_down > LONG_PRESS_THRESHOLD and not btn_alt_fired then
            command_once("FJS/Q4XP/SoftKey/ap_altsel")
            btn_alt_fired = true
        end
    elseif btn_alt_time_down > 0 then
        if now - btn_alt_time_down < LONG_PRESS_THRESHOLD then
            command_once("FJS/Q4XP/SoftKey/ap_alt")
        elseif not btn_alt_fired then
            command_once("FJS/Q4XP/SoftKey/ap_altsel")
        end

        btn_alt_time_down = 0
    end

    if button(AP_BTN_VS) then
        if btn_vs_time_down == 0 then
            btn_vs_time_down = now
            btn_vs_fired = false
        elseif now - btn_vs_time_down > LONG_PRESS_THRESHOLD and not btn_vs_fired then
            command_once("FJS/Q4XP/SoftKey/ap_vnav")
            btn_vs_fired = true
        end
    elseif btn_vs_time_down > 0 then
        if now - btn_vs_time_down < LONG_PRESS_THRESHOLD then
            command_once("FJS/Q4XP/SoftKey/ap_vs")
        elseif not btn_vs_fired then
            command_once("FJS/Q4XP/SoftKey/ap_vnav")
        end

        btn_vs_time_down = 0
    end

    if button(AP_BTN_AP) then
        if btn_ap_time_down == 0 then
            btn_ap_time_down = now
            btn_ap_fired = false
        elseif now - btn_ap_time_down > LONG_PRESS_THRESHOLD and not btn_ap_fired then
            command_once("FJS/Q4XP/SoftKey/ap_stby")
            btn_ap_fired = true
        end
    elseif btn_ap_time_down > 0 then
        if now - btn_ap_time_down < LONG_PRESS_THRESHOLD then
            command_once("FJS/Q4XP/SoftKey/ap_ap")
        elseif not btn_ap_fired then
            command_once("FJS/Q4XP/SoftKey/ap_stby")
        end

        btn_ap_time_down = 0
    end
end

if PLANE_ICAO == "DH8D" then
    create_command("Q4XP_Helper/prop1_down", "", "q4xp_hh_begin_prop(\"down\", 1)", "", "")
    create_command("Q4XP_Helper/prop2_down", "", "q4xp_hh_begin_prop(\"down\", 2)", "", "")
    create_command("Q4XP_Helper/prop1_up", "", "q4xp_hh_begin_prop(\"up\", 1)", "", "")
    create_command("Q4XP_Helper/prop2_up", "", "q4xp_hh_begin_prop(\"up\", 2)", "", "")

    do_often("q4xp_hh_update_props()")
    do_often("q4xp_hh_update_parking_brake()")

    do_on_keystroke("q4xp_hh_fmc_typer()")
    do_every_draw("q4xp_hh_advise_fmc_typer()")

    do_every_frame("q4xp_hh_simulate_missing_buttons()")
    do_every_draw("_draw_msg()")

    for i=0,6 do
        ap_lights_table[i] = 0
    end
    do_every_frame("q4xp_hh_update_ap_leds()")
end

-- helper methods

function now_ms()
    return socket.gettime() * 1000
end

function draw_message_for(duration_sec, msg)
    msg_text = msg
    msg_visible_time = duration_sec * 1000
    msg_shown_at = now_ms()
end

function _draw_msg()
    if msg_visible_time > 0 then
        glColor4f(0, 0, 0, 255)
        draw_string_Helvetica_18(50 - 1, 130 - 1, msg_text)
        draw_string_Helvetica_18(50 + 1, 130 + 1, msg_text)
        draw_string_Helvetica_18(50 + 1, 130 - 1, msg_text)
        draw_string_Helvetica_18(50 - 1, 130 + 1, msg_text)
        glColor4f(1, 1, 1, 255)
        draw_string_Helvetica_18(50, 130, msg_text)
        if now_ms() - msg_shown_at >= msg_visible_time then
            msg_visible_time = 0
            msg_shown_at = 0
            msg_text = ""
        end
    end
end

function btn_set(btn, state)
    if state == "on" then
        ap_blinking[btn] = -1
    elseif state == "off" then
        ap_blinking[btn] = 0
    elseif state == "blink" or state == "slow" then
        ap_blinking[btn] = 1
    elseif state == "fast" then
        ap_blinking[btn] = 2
    end
end

function btn_get(btn)
    if ap_blinking[btn] == -1 then return "on" end
    if ap_blinking[btn] == 0 then return "off" end
    if ap_blinking[btn] == 1 then return "blink" end
    if ap_blinking[btn] == 2 then return "fasat" end
end

function xor(a, b)
    return (a and not b) or (b and not a)
end