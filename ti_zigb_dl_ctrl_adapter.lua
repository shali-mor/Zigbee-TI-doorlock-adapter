local _M = {}

local SIMULATE_DONGLE = true

local log = require('rcaf.log')
local dal = require('rcaf.device_abstraction_layer')
local dev = require('rcaf.device')
local str = require('rcaf.string_utils')
local events = require('rcaf.events')
local ev = require('ev')
local json = require('cjson')
if SIMULATE_DONGLE == false then
local CC2531 = require "CC2531Ctr"
end
local msgbus = require('rcaf.msgbus')
local pushover = require('rcaf.PushOver') 

local adapter
local dl_controller = nil
local door_lock_id = nil
local door_locked = true
local door_lock_service_enabled = false
local door_lock_guard_enabled = false

local DOOR_LOCK_CONTROLLER_SERIVE_ID = '1'
local DOOR_LOCK_DEVICE_SETTINGS_SERVICE_ID = '3'

--this value will be used to prvant replay attack
local seq_num = 0

local function door_lock_connected(door_lock)
  -- build door lock id by idVendor+idProduct+_usb_addr
  door_lock_id = tostring(door_lock._usb_desc.idVendor) .. ':' .. tostring(door_lock._usb_desc.idProduct) .. ':' .. tostring(door_lock._usb_addr)
  -- if we got here, the door lock is online
  local status = dev.status.ONLINE
  local vendor = "TI"
  
  print("adding device id" .. door_lock_id)
  adapter.device_added(door_lock_id, status,
    {
      {
        id = DOOR_LOCK_CONTROLLER_SERIVE_ID,
        type = dev.service.LOCK,
        characteristics = {
          [dev.characteristic.DOOR_LOCKED] =  door_locked,	  
	  [dev.characteristic.SEQ_NUM] =  seq_num,
        },
      },
      {
        id = DOOR_LOCK_DEVICE_SETTINGS_SERVICE_ID,
        type = dev.service.DEVICE_SETTINGS,
        characteristics = {
          [dev.characteristic.ENABLED] =  door_lock_service_enabled,
          [dev.characteristic.GUARD_ENABLED] =  door_lock_guard_enabled,
        },
      },
    },
    {
      [dev.property.VENDOR_ID] = door_lock._usb_desc.idVendor,
      [dev.property.PRODUCT_ID] = door_lock._usb_desc.idProduct,
    }
  )
end

local function handle_door_lock_service_enabled(changeset)
  if type(changeset.characteristics[dev.characteristic.ENABLED]) == "boolean" then
    if door_lock_service_enabled ~= changeset.characteristics[dev.characteristic.ENABLED] then
      door_lock_service_enabled = changeset.characteristics[dev.characteristic.ENABLED] 
      log.d("Door Lock service enable flag changed to " .. tostring(door_lock_service_enabled))
    end
  end
  
  return changeset
end

local function handle_guard_enabled(changeset)
  if type(changeset.characteristics[dev.characteristic.GUARD_ENABLED]) == "boolean" then
    if door_lock_guard_enabled ~= changeset.characteristics[dev.characteristic.GUARD_ENABLED] then
      door_lock_guard_enabled = changeset.characteristics[dev.characteristic.GUARD_ENABLED] 
      log.d("Door Lock guard changed to " .. tostring(door_lock_guard_enabled))
    end
  end
  
  return changeset  
end

local function handle_door_locked(changeset)
   if type(changeset.characteristics[dev.characteristic.DOOR_LOCKED]) == "boolean" then
      if door_lock_service_enabled == true then
	 if changeset.characteristics[dev.characteristic.DOOR_LOCKED] ~= door_locked then
	    do_toggle_door = false
	    if door_lock_guard_enabled == true then
	       if seq_num < changeset.characteristics[dev.characteristic.SEQ_NUM] then
		  do_toggle_door = true
	       else
		  --send Push notification - "Replay attack was blocked by homeguard"
--		  pushover.SendMsgToAdmin('Your home GW is Under Attack - replay attack was blocked by homeguard')


		  pushover.SendMsgToAdmin('An unauthorised attempt to open your door was identified and blocked by HomeGuard.')
	       end
	    else
	       do_toggle_door = true
	    end 

	    if do_toggle_door then
	       seq_num = seq_num + 1
	       --Change door state as service enabled
	       dl_controller.toggle_door_lock()
	       door_locked = changeset.characteristics[dev.characteristic.DOOR_LOCKED]
	       log.d("Door Locked status changed to " .. tostring(door_locked) .. " seq_num = " .. tostring(seq_num))	   
	       msgbus.call('home_guard.device_state_changed', "door locked", door_locked and "open" or "close")
	    end	    

	 end  
      else
	 log.d("Could not change door lock state, when service disabled!!!")
	 --Override door lock state in changeset as its change request rejected
	 changeset.characteristics[dev.characteristic.DOOR_LOCKED] = door_locked 
      end
      changeset.characteristics[dev.characteristic.SEQ_NUM] = seq_num 

   end  
   
   return changeset
end

local function start()
  local err

  adapter, err = dal.adapter_register(
    '2620537E-6F69-32A6-8592-008814F22B3A', 'DoorLock Controller', {
      device_characteristics_set = function(device_id, changeset)
        for k,v in pairs(changeset) do
          print(k,v)
          if type(v) == "table" then
            for a,b in pairs(v) do
              print(a,b)
            end              
          end
        end

        --Verify door lock id        
        if device_id ~= door_lock_id then log.e("incorrect device id, expected id" .. device_id .. " " .. door_lock_id) return end
        
        --Enabling/Disabling service
        changeset = handle_door_lock_service_enabled( changeset )
  
        --Enabling/Disabling home guard for service
        changeset = handle_guard_enabled( changeset )
        
        --Control DoorLock
        changeset = handle_door_locked(changeset)
        
        adapter.device_characteristic_changed(device_id, {characteristics = changeset})
      end,
      
     device_enroll = function(data)
        log.d('Got request to enroll device')
      end,
      
      device_remove = function(device_id)
        log.d('Got request to remove device %s' % device_id)
        adapter.device_removed(device_id)
      end,
      
      pass_through_action = function(data)
        log.d('Got request for path_through action')
      end,
    })
  assert(adapter, err)
  
  ev.Timer.new(
    function(timer, loop, revents)
      if dl_controller == nil then
        if SIMULATE_DONGLE == false then
          dev_list = CC2531.get_CC2531()
          if table.getn(dev_list) ~= 0 then
            dl_controller = CC2531.CC2531(dev_list[1])
            log.d("Found DoorLock controller")
            door_lock_connected(dl_controller)
          else
            log.d("DoorLock controller not connected")
          end
        else
          --Simulator for low level DL controller
          dl_controller = {}
          dl_controller._usb_desc = {}
          
          dl_controller._usb_desc.idVendor = 0x451
          dl_controller._usb_desc.idProduct = 0x16a8
          dl_controller._usb_addr = 1
          
          dl_controller.toggle_door_lock = 
            function ()
              log.d("Mocked DoorLock state changed");
              return
            end
          
          door_lock_connected(dl_controller)
        end
      else
        --log.d("DoorLock connected")  
      end
    end, 5, 5):start(ev.Loop.default)
end
_M.start = start

local function stop()
  log.d("Got request to stop adapter")
  if adapter then adapter.unregister() end
end
_M.stop = stop

return _M
