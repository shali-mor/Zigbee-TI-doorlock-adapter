usbdrv = require "libusb1"
string = require "string"
math = require "math"

VID = 0x0451
PID = 0x16a8

_M = {}

function hexlify(s)
    local a = {}
    for i=1,#s do
        local c = string.sub(s,i,i)
        local byte = string.byte(c)
        table.insert(a, string.format('%02X', byte))
    end
    return table.concat(a)
end

local function dbg_out(...)
--  print(arg)
end

local function dev_construct(CC2531_dev)
  local self = {}
  self.usb_desc = {}
  self.dev = CC2531_dev
  self.inner_handle = nil
  self.usb_desc = usbdrv.get_device_descriptor(CC2531_dev)
  
    --
  -- CC2531 dongle internal configuration settings length
  self.CTRL_LEN = {}
  self.CTRL_LEN[192] = 256
  self.CTRL_LEN[198] = 1
  self.CTRL_LEN[210] = 1
  
  --only a single interface to control over
  self.IF = 0
  
  for i,v in pairs(self.usb_desc) do
    dbg_out (i,v)
  end
  
  self.getProduct = 
    function ()
      return self.dev.get_device_descriptor(self.dev)
    end
  
  self.getBusNumber = 
   function ()
    return self.dev.get_bus_number(self.dev)
   end
   
  self.getDeviceAddress = 
   function()
    return self.dev.get_device_address(self.dev)
   end
    
  self.getbcdDevice = 
   function ()
    return self.usb_desc.bcdDevice
   end
   
  self.open = 
   function()
    self.com, err = self.dev.open(self.dev)
    -- un-load possible kernel driver
    self.com.kernel_driver_active(self.com, self.IF)
    self.com.detach_kernel_driver(self.com, self.IF)
    self.com.claim_interface(self.com, self.IF)
   end
  
  self.close = 
    function()
      self.com.release_interface(self.com, self.IF)
      self.com.close(self.com)
      return
    end
   
   self.set_config = 
    function(c)
      dbg_out('set_config: c=' .. c .. ' request_type=' .. usbdrv.LIBUSB_TRANSFER_TYPE_CONTROL + usbdrv.LIBUSB_ENDPOINT_OUT .. 'request=' .. usbdrv.LIBUSB_REQUEST_SET_CONFIGURATION)
      local ret = self.com.control_transfer_wo_data(self.com, usbdrv.LIBUSB_TRANSFER_TYPE_CONTROL + usbdrv.LIBUSB_ENDPOINT_OUT , usbdrv.LIBUSB_REQUEST_SET_CONFIGURATION, c, 0, 0)
      dbg_out ('set_config: control transfer returns ' .. ret)
    end
    
    self.get_ctrl = 
      function(c)
        if self.CTRL_LEN[c] == nil then
          l = 0x100
        else
          l = self.CTRL_LEN[c]
        end
        dbg_out ('get_ctrl: c=' .. c ..  ' l=' .. l)
        local ret = self.com.control_transfer(self.com, usbdrv.LIBUSB_REQUEST_TYPE_VENDOR + usbdrv.LIBUSB_ENDPOINT_IN, c, 0, 0, l)
        dbg_out ('get_ctrl: control transfer ret type ' .. type(ret) .. ' value = ' .. hexlify(ret))
      end        
     
     self.set_feature =
      function(c)
        local ret = self.com.control_transfer_wo_data(self.com, usbdrv.LIBUSB_TRANSFER_TYPE_CONTROL + usbdrv.LIBUSB_ENDPOINT_OUT , usbdrv.LIBUSB_REQUEST_SET_FEATURE, c, 0, 0)
      end
        
  return self
end
   
-- returns the list of CC2531 plugged in
local function get_CC2531()
  cc2351_dev_list = {}
  device_count = 0
  usbdrv.init()
  dev_list = usbdrv.get_device_list()
  
  dbg_out ("reviewing device list")

  for i,v in pairs(dev_list) do
    dbg_out ("===============================")
    dbg_out ("device number", i)
    dbg_out ("===============================")
    device_desc = usbdrv.get_device_descriptor(dev_list[i])
    for j,u in pairs(device_desc) do
--      dbg_out (j, u)
    end
    if ((device_desc.idVendor == VID) and (device_desc.idProduct == PID)) then
      device_count = device_count + 1
      cc2351_dev_list[device_count] = dev_list[i]
    end
  end
  
  return cc2351_dev_list
end
_M.get_CC2531 = get_CC2531

-- drives a CC2531 loaded with the default TI firmware sniffer
function CC2531(CC2531_dev)
    local self = {}
    --[[
    Drive a TI CC2531 802.15.4 dongle through python libusb1.
    ---
    It needs to be instanciated with a USB descriptor,
    such as one returned by get_CC2531() function.
    ---
    Basic methods allow to drive the dongle:
    .init() : re-init the dongle
    ---
    See the test() function at the end of the file for basic use 
    of this class
    --]]
    -- from 0 (silent) to 3 (very verbose)
    DEBUG = 1
    
    VID = VID
    PID = PID
      
    self.dev = dev_construct(CC2531_dev)

    self._log = dbg_out
    self._usb_desc = self.dev.getProduct()
    self._usb_bus = self.dev.getBusNumber()
    self._usb_addr = self.dev.getDeviceAddress()
    self._usb_serial = self.dev.getbcdDevice()
    self._log('driving ' .. type(self._usb_desc) .. ' @ USB bus ' .. self._usb_bus .. ' & address ' .. self._usb_addr .. ' , with serial ' .. self._usb_serial)
        --
    self.dev.open()
    -- init state
    self._sniffing = false

--    def _log(self, msg=''):
--        LOG('[%i] %s' % (self._usb_serial, msg))
    self.open = 
      function()
        return self.dev.open()
      end
    
    self.close = 
      function()
        return self.dev.close()
      end
    
    ---
    -- dongle config sequence (captured from a windows session):
    -- _set_config(0), ...
    -- _get_ctrl(192), ...
    -- _set_config(1), ...
    -- _set_ctrl(197, 4), _get_ctrl(198) {3,}, _set_ctrl(201, 0), _set_ctl(210, 0), _set_ctrl(210, 1), _set_ctrl(208, 0)
    -- -> bulk transfer
    --  _set_ctrl(209, 0), _set_ctrl(197, 0), _set_config(0), ...
    ---
    self._set_config =
      function(c)
        return self.dev.set_config(c)
      end
    
    self._get_ctrl = 
      function(c)
        return self.dev.get_ctrl(c)
      end

    self._set_ctrl = 
      function(c, i)
        return self.dev.set_ctrl(c, i)
      end
    
    self._set_feature = 
      function(c)
        return self.dev.set_feature(c)
      end
    
    ---
    -- macro sequences for controlling the CC2531 dongle
    ---
    self.init =
      function()
        self._set_config(0)
--      self._get_ctrl(192)
        dbg_out('(init) done')
      end
    
    self.toggle_ez_mode =
      function()
        local ret = self._set_feature(2)
       end
    
    self.toggle_door_lock =
      function()
        local ret = self._set_feature(3)
       end

    return self    
end
_M.CC2531 = CC2531

return _M
