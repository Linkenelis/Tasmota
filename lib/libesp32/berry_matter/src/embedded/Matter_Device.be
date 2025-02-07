#
# Matter_Device.be - implements a generic Matter device (commissionee)
#
# Copyright (C) 2023  Stephan Hadinger & Theo Arends
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

#@ solidify:Matter_Device,weak

class Matter_Device
  static var UDP_PORT = 5540          # this is the default port for group multicast, we also use it for unicast
  static var PASSCODE_DEFAULT = 20202021
  static var PBKDF_ITERATIONS = 1000  # I don't see any reason to choose a different number
  static var VENDOR_ID = 0xFFF1
  static var PRODUCT_ID = 0x8000
  static var FILENAME = "_matter_device.json"
  var plugins                         # list of plugins
  var udp_server                      # `matter.UDPServer()` object
  var message_handler                     # `matter.MessageHandler()` object
  var sessions                        # `matter.Session_Store()` objet
  var ui
  # information about the device
  var commissioning_instance_wifi     # random instance name for commissioning
  var commissioning_instance_eth      # random instance name for commissioning
  var hostname_wifi                   # MAC-derived hostname for commissioning
  var hostname_eth                    # MAC-derived hostname for commissioning
  var vendorid
  var productid
  # saved in parameters
  var discriminator
  var passcode
  var ipv4only                        # advertize only IPv4 addresses (no IPv6)
  # context for PBKDF
  var iterations
  # PBKDF information used only during PASE (freed afterwards)
  var salt
  var w0, w1, L

  #############################################################
  def init()
    import crypto
    import string
    if !tasmota.get_option(matter.MATTER_OPTION)
      matter.UI(self)   # minimal UI
      return
    end    # abort if SetOption 151 is not set

    self.plugins = []
    self.vendorid = self.VENDOR_ID
    self.productid = self.PRODUCT_ID
    self.iterations = self.PBKDF_ITERATIONS
    self.ipv4only = false
    self.load_param()
    self.commissioning_instance_wifi = crypto.random(8).tohex()    # 16 characters random hostname
    self.commissioning_instance_eth = crypto.random(8).tohex()    # 16 characters random hostname

    self.sessions = matter.Session_Store()
    self.sessions.load()
    self.message_handler = matter.MessageHandler(self)
    self.ui = matter.UI(self)

    # add the default plugin
    self.plugins.push(matter.Plugin_Root(self))
    self.plugins.push(matter.Plugin_OnOff(self))

    self.start_mdns_announce_hostnames()

    if tasmota.wifi()['up']
      self.start_udp(self.UDP_PORT)
    else
      tasmota.add_rule("Wifi#Connected", def ()
          self.start_udp(self.UDP_PORT)
          tasmota.remove_rule("Wifi#Connected", "matter_device_udp")

        end, self)
    end

    if tasmota.eth()['up']
      self.start_udp(self.UDP_PORT)
    else
      tasmota.add_rule("Eth#Connected", def ()
          self.start_udp(self.UDP_PORT)
          tasmota.remove_rule("Eth#Connected", "matter_device_udp")
        end, self)
    end

    self.start_basic_commissioning()

    tasmota.add_driver(self)
  end

  #############################################################
  # Start Basic Commissioning Window
  def start_basic_commissioning()
    # compute PBKDF
    self.compute_pbkdf(self.passcode)
  end

  def finish_commissioning()
  end

  #############################################################
  # Compute the PBKDF parameters for SPAKE2+
  #
  # iterations is set to 1000 which is large enough
  def compute_pbkdf(passcode_int)
    import crypto
    self.salt = crypto.random(16)         # bytes("5350414B453250204B65792053616C74")
    var passcode = bytes().add(passcode_int, 4)

    var tv = crypto.PBKDF2_HMAC_SHA256().derive(passcode, self.salt, self.iterations, 80)
    var w0s = tv[0..39]
    var w1s = tv[40..79]

    self.w0 = crypto.EC_P256().mod(w0s)
    self.w1 = crypto.EC_P256().mod(w1s)
    self.L = crypto.EC_P256().public_key(self.w1)

    tasmota.log("MTR: ******************************", 3)
    tasmota.log("MTR: salt          = " + self.salt.tohex(), 3)
    tasmota.log("MTR: passcode      = " + passcode.tohex(), 3)
    tasmota.log("MTR: w0            = " + self.w0.tohex(), 3)
    tasmota.log("MTR: w1            = " + self.w1.tohex(), 3)
    tasmota.log("MTR: L             = " + self.L.tohex(), 3)
    tasmota.log("MTR: ******************************", 3)
  end

  #############################################################
  # compute QR Code content
  def compute_qrcode_content()
    var raw = bytes().resize(11)    # we don't use TLV Data so it's only 88 bits or 11 bytes
    # version is `000` dont touch
    raw.setbits(3, 16, self.vendorid)
    raw.setbits(19, 16, self.productid)
    # custom flow = 0 (offset=35, len=2)
    raw.setbits(37, 8, 0x04)        # already on IP network
    raw.setbits(45, 12, self.discriminator & 0xFFF)
    raw.setbits(57, 27, self.passcode & 0x7FFFFFF)
    # padding (offset=84 len=4)
    return "MT:" + matter.Base38.encode(raw)
  end


  #############################################################
  # compute the 11 digits manual pairing code (wihout vendorid nor productid) p.223
  def compute_manual_pairing_code()
    import string
    var digit_1 = (self.discriminator & 0x0FFF) >> 10
    var digit_2_6 = ((self.discriminator & 0x0300) << 6) | (self.passcode & 0x3FFF)
    var digit_7_10 = (self.passcode >> 14)

    var ret = string.format("%1i%05i%04i", digit_1, digit_2_6, digit_7_10)
    ret += matter.Verhoeff.checksum(ret)
    return ret
  end

  #############################################################
  # dispatch every second click to sub-objects that need it
  def every_second()
    self.sessions.every_second()
    self.message_handler.every_second()
  end

  #############################################################
  # dispatch every 250ms click to sub-objects that need it
  def every_250ms()
    self.message_handler.every_250ms()
  end

  #############################################################
  def stop()
    if self.udp_server    self.udp_server.stop() end
  end

  #############################################################
  # callback when message is received
  def msg_received(raw, addr, port)
    return self.message_handler.msg_received(raw, addr, port)
  end

  def msg_send(raw, addr, port, id)
    return self.udp_server.send_response(raw, addr, port, id)
  end

  def packet_ack(id)
    return self.udp_server.packet_ack(id)
  end

  #############################################################
  # Start UDP Server
  def start_udp(port)
    if self.udp_server    return end        # already started
    if port == nil      port = 5540 end
    tasmota.log("MTR: starting UDP server on port: " + str(port), 2)
    self.udp_server = matter.UDPServer("", port)
    self.udp_server.start(/ raw, addr, port -> self.msg_received(raw, addr, port))
  end

  #############################################################
  # start_operational_dicovery
  #
  # Pass control to `device`
  def start_operational_dicovery_deferred(session)
    # defer to next click
    tasmota.set_timer(0, /-> self.start_operational_dicovery(session))
  end

  #############################################################
  def start_commissioning_complete_deferred(session)
    # defer to next click
    tasmota.set_timer(0, /-> self.start_commissioning_complete(session))
  end

  #############################################################
  # Start Operational Discovery
  def start_operational_dicovery(session)
    import crypto
    import mdns
    import string

    # clear any PBKDF information to free memory
    self.salt = nil
    self.w0 = nil
    self.w1 = nil
    self.L = nil

    # save session as persistant
    session.set_no_expiration()
    session.set_persist(true)
    # close the PASE session, it will be re-opened with a CASE session
    session.close()
    self.sessions.save()

    self.mdns_announce_op_discovery(session)
  end

  #############################################################
  # Commissioning Complete
  #
  def start_commissioning_complete(session)
    tasmota.log("MTR: *** Commissioning complete ***", 2)
  end


  #################################################################################
  # Simple insertion sort - sorts the list in place, and returns the list
  # remove duplicates
  #################################################################################
  static def sort_distinct(l)
    # insertion sort
    for i:1..size(l)-1
      var k = l[i]
      var j = i
      while (j > 0) && (l[j-1] > k)
        l[j] = l[j-1]
        j -= 1
      end
      l[j] = k
    end
    # remove duplicate now that it's sorted
    var i = 1
    if size(l) <= 1  return l end     # no duplicate if empty or 1 element
    var prev = l[0]
    while i < size(l)
      if l[i] == prev
        l.remove(i)
      else
        prev = l[i]
        i += 1
      end
    end
    return l
  end

  #############################################################
  # signal that an attribute has been changed
  #
  def attribute_updated(endpoint, cluster, attribute, fabric_specific)
    if fabric_specific == nil   fabric_specific = false end
    var ctx = matter.Path()
    ctx.endpoint = endpoint
    ctx.cluster = cluster
    ctx.attribute = attribute
    self.message_handler.im.subs.attribute_updated_ctx(ctx, fabric_specific)
  end

  #############################################################
  # expand attribute list based 
  #
  # called only when expansion is needed,
  # so we don't need to report any error since they are ignored
  def process_attribute_expansion(ctx, cb)
    #################################################################################
    # Returns the keys of a map as a sorted list
    #################################################################################
    def keys_sorted(m)
      var l = []
      for k: m.keys()
        l.push(k)
      end
      # insertion sort
      for i:1..size(l)-1
        var k = l[i]
        var j = i
        while (j > 0) && (l[j-1] > k)
          l[j] = l[j-1]
          j -= 1
        end
        l[j] = k
      end
      return l
    end
  
    import string
    var endpoint = ctx.endpoint
    # var endpoint_mono = [ endpoint ]
    var endpoint_found = false                # did any endpoint match
    var cluster = ctx.cluster
    # var cluster_mono = [ cluster ]
    var cluster_found = false
    var attribute = ctx.attribute
    # var attribute_mono = [ attribute ]
    var attribute_found = false

    var direct = (ctx.endpoint != nil) && (ctx.cluster != nil) && (ctx.attribute != nil) # true if the target is a precise attribute, false if it results from an expansion and error are ignored

    tasmota.log(string.format("MTR: process_attribute_expansion %s", str(ctx)), 4)

    # build the list of candidates

    # list of all endpoints
    var all = {}                          # map of {endpoint: {cluster: {attributes:[pi]}}
    tasmota.log(string.format("MTR: endpoint=%s cluster=%s attribute=%s", endpoint, cluster, attribute), 4)
    for pi: self.plugins
      var ep_list = pi.get_endpoints()    # get supported endpoints for this plugin
      tasmota.log(string.format("MTR: pi=%s ep_list=%s", str(pi), str(ep_list)), 4)
      for ep: ep_list
        if endpoint != nil && ep != endpoint    continue      end       # skip if specific endpoint and no match
        # from now on, 'ep' is a good candidate
        if !all.contains(ep)                    all[ep] = {}  end       # create empty structure if not already in the list
        endpoint_found = true

        # now explore the cluster list for 'ep'
        var cluster_list = pi.get_cluster_list(ep)                      # cluster_list is the actual list of candidate cluster for this pluging and endpoint
        tasmota.log(string.format("MTR: pi=%s ep=%s cl_list=%s", str(pi), str(ep), str(cluster_list)), 4)
        for cl: cluster_list
          if cluster != nil && cl != cluster    continue      end       # skip if specific cluster and no match
          # from now on, 'cl' is a good candidate
          if !all[ep].contains(cl)              all[ep][cl] = {}  end
          cluster_found = true

          # now filter on attributes
          var attr_list = pi.get_attribute_list(ep, cl)
          tasmota.log(string.format("MTR: pi=%s ep=%s cl=%s at_list=%s", str(pi), str(ep), str(cl), str(attr_list)), 4)
          for at: attr_list
            if attribute != nil && at != attribute  continue  end       # skip if specific attribute and no match
            # from now on, 'at' is a good candidate
            if !all[ep][cl].contains(at)        all[ep][cl][at] = [] end
            attribute_found = true

            all[ep][cl][at].push(pi)                                    # add plugin to the list
          end
        end
      end
    end

    # import json
    # tasmota.log("MTR: all = " + json.dump(all), 2)

    # iterate on candidates
    for ep: keys_sorted(all)
      for cl: keys_sorted(all[ep])
        for at: keys_sorted(all[ep][cl])
          for pi: all[ep][cl][at]
            tasmota.log(string.format("MTR: expansion [%02X]%04X/%04X", ep, cl, at), 3)
            ctx.endpoint = ep
            ctx.cluster = cl
            ctx.attribute = at
            var finished = cb(pi, ctx, direct)   # call the callback with the plugin and the context
            if direct && finished     return end
          end
        end
      end
    end

    # we didn't have any successful match, report an error if direct (non-expansion request)
    if direct
      # since it's a direct request, ctx has already the correct endpoint/cluster/attribute
      if   !endpoint_found      ctx.status = matter.UNSUPPORTED_ENDPOINT
      elif !cluster_found       ctx.status = matter.UNSUPPORTED_CLUSTER
      elif !attribute_found     ctx.status = matter.UNSUPPORTED_ATTRIBUTE
      else                      ctx.status = matter.UNREPORTABLE_ATTRIBUTE
      end
      cb(nil, ctx, true)
    end
  end

  #############################################################
  # get active endpoints
  #
  # return the list of endpoints from all plugins (distinct)
  def get_active_endpoints(exclude_zero)
    var ret = []
    for p:self.plugins
      var e = p.get_endpoints()
      for elt:e
        if exclude_zero && elt == 0   continue end
        if ret.find(elt) == nil
          ret.push(elt)
        end
      end
    end
    return ret
  end

  #############################################################
  # Persistance of Matter Device parameters
  #
  #############################################################
  # 
  def save_param()
    import json
    var j = json.dump({'distinguish':self.discriminator, 'passcode':self.passcode, 'ipv4only':self.ipv4only})
    try
      import string
      var f = open(self.FILENAME, "w")
      f.write(j)
      f.close()
      return j
    except .. as e, m
      tasmota.log("MTR: Session_Store::save Exception:" + str(e) + "|" + str(m), 2)
      return j
    end
  end

  #############################################################
  def load_param()
    import string
    import crypto
    try

      var f = open(self.FILENAME)
      var s = f.read()
      f.close()

      import json
      var j = json.load(s)

      self.discriminator = j.find("distinguish", self.discriminator)
      self.passcode = j.find("passcode", self.passcode)
      self.ipv4only = bool(j.find("ipv4only", false))
    except .. as e, m
      if e != "io_error"
        tasmota.log("MTR: Session_Store::load Exception:" + str(e) + "|" + str(m), 2)
      end
    end

    var dirty = false
    if self.discriminator == nil
      self.discriminator = crypto.random(2).get(0,2) & 0xFFF
      dirty = true
    end
    if self.passcode == nil
      self.passcode = self.PASSCODE_DEFAULT
      dirty = true
    end
    if dirty    self.save_param() end
  end


  #############################################################
  # Matter plugin management
  #
  # Plugins allow to specify response to read/write attributes
  # and command invokes
  #############################################################
  def invoke_request(session, val, ctx)
    var idx = 0
    while idx < size(self.plugins)
      var plugin = self.plugins[idx]

      var ret = plugin.invoke_request(session, val, ctx)
      if  ret != nil || ctx.status != matter.UNSUPPORTED_COMMAND  # default value
        return ret
      end

      idx += 1
    end
  end

  #############################################################
  # MDNS Configuration
  #############################################################
  # Start MDNS and announce hostnames for Wifi and ETH from MAC
  #
  # When the announce is active, `hostname_wifi` and `hostname_eth`
  # are defined
  def start_mdns_announce_hostnames()
    if tasmota.wifi()['up']
      self._start_mdns_announce(false)
    else
      tasmota.add_rule("Wifi#Connected", def ()
          self._start_mdns_announce(false)
          tasmota.remove_rule("Wifi#Connected", "matter_device_mdns")
        end, self)
    end

    if tasmota.eth()['up']
      self._start_mdns_announce(true)
    else
      tasmota.add_rule("Eth#Connected", def ()
          self._start_mdns_announce(true)
          tasmota.remove_rule("Eth#Connected", "matter_device_mdns")
        end, self)
    end
  end

  #############################################################
  # Start UDP mDNS announcements for commissioning
  #
  # eth is `true` if ethernet turned up, `false` is wifi turned up
  def _start_mdns_announce(is_eth)
    import mdns
    import string

    mdns.start()

    var services = {
      "VP":str(self.vendorid) + "+" + str(self.productid),
      "D": self.discriminator,
      "CM":1,                           # requires passcode
      "T":0,                            # no support for TCP
      "SII":5000, "SAI":300
    }

    # mdns
    try
      if is_eth
        var eth = tasmota.eth()
        self.hostname_eth  = string.replace(eth.find("mac"), ':', '')
        if !self.ipv4only
          mdns.add_hostname(self.hostname_eth, eth.find('ip6local',''), eth.find('ip',''), eth.find('ip6',''))
        else
          mdns.add_hostname(self.hostname_eth, eth.find('ip',''))
        end
        mdns.add_service("_matterc", "_udp", 5540, services, self.commissioning_instance_eth, self.hostname_eth)

        tasmota.log(string.format("MTR: starting mDNS on %s '%s' ptr to `%s.local`", is_eth ? "eth" : "wifi",
        is_eth ? self.commissioning_instance_eth : self.commissioning_instance_wifi,
        is_eth ? self.hostname_eth : self.hostname_wifi), 2)

        # `mdns.add_subtype(service:string, proto:string, instance:string, hostname:string, subtype:string) -> nil`
        var subtype = "_L" + str(self.discriminator & 0xFFF)
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matterc", "_udp", self.commissioning_instance_eth, self.hostname_eth, subtype)
        subtype = "_S" + str((self.discriminator & 0xF00) >> 8)
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matterc", "_udp", self.commissioning_instance_eth, self.hostname_eth, subtype)
        subtype = "_V" + str(self.vendorid)
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matterc", "_udp", self.commissioning_instance_eth, self.hostname_eth, subtype)
        subtype = "_CM1"
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matterc", "_udp", self.commissioning_instance_eth, self.hostname_eth, subtype)
      else
        var wifi = tasmota.wifi()
        self.hostname_wifi = string.replace(wifi.find("mac"), ':', '')
        if !self.ipv4only
          mdns.add_hostname(self.hostname_wifi, wifi.find('ip6local',''), wifi.find('ip',''), wifi.find('ip6',''))
        else
          mdns.add_hostname(self.hostname_wifi, wifi.find('ip',''))
        end
        mdns.add_service("_matterc", "_udp", 5540, services, self.commissioning_instance_wifi, self.hostname_wifi)

        tasmota.log(string.format("MTR: starting mDNS on %s '%s' ptr to `%s.local`", is_eth ? "eth" : "wifi",
        is_eth ? self.commissioning_instance_eth : self.commissioning_instance_wifi,
        is_eth ? self.hostname_eth : self.hostname_wifi), 2)

        # `mdns.add_subtype(service:string, proto:string, instance:string, hostname:string, subtype:string) -> nil`
        var subtype = "_L" + str(self.discriminator & 0xFFF)
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matterc", "_udp", self.commissioning_instance_wifi, self.hostname_wifi, subtype)
        subtype = "_S" + str((self.discriminator & 0xF00) >> 8)
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matterc", "_udp", self.commissioning_instance_wifi, self.hostname_wifi, subtype)
        subtype = "_V" + str(self.vendorid)
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matterc", "_udp", self.commissioning_instance_wifi, self.hostname_wifi, subtype)
        subtype = "_CM1"
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matterc", "_udp", self.commissioning_instance_wifi, self.hostname_wifi, subtype)
      end
    except .. as e, m
      tasmota.log("MTR: Exception" + str(e) + "|" + str(m), 2)
    end

    self.mdns_announce_op_discovery_all_sessions()
  end

  #############################################################
  # Start UDP mDNS announcements for commissioning for all persisted sessions
  def mdns_announce_op_discovery_all_sessions()
    for session: self.sessions.sessions
      if session.get_deviceid() && session.get_fabric()
        self.mdns_announce_op_discovery(session)
      end
    end
  end

  #############################################################
  # Start UDP mDNS announcements for commissioning
  def mdns_announce_op_discovery(session)
    import mdns
    import string
    try
      var device_id = session.get_deviceid().copy().reverse()
      var k_fabric = session.get_fabric_compressed()
      var op_node = k_fabric.tohex() + "-" + device_id.tohex()
      tasmota.log("MTR: Operational Discovery node = " + op_node, 2)

      # mdns
      if (tasmota.eth().find("up"))
        tasmota.log(string.format("MTR: adding mDNS on %s '%s' ptr to `%s.local`", "eth", op_node, self.hostname_eth), 3)
        mdns.add_service("_matter","_tcp", 5540, nil, op_node, self.hostname_eth)
        var subtype = "_I" + k_fabric.tohex()
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matter", "_tcp", op_node, self.hostname_eth, subtype)
      end
      if (tasmota.wifi().find("up"))
        tasmota.log(string.format("MTR: adding mDNS on %s '%s' ptr to `%s.local`", "wifi", op_node, self.hostname_wifi), 3)
        mdns.add_service("_matter","_tcp", 5540, nil, op_node, self.hostname_wifi)
        var subtype = "_I" + k_fabric.tohex()
        tasmota.log("MTR: adding subtype: "+subtype, 3)
        mdns.add_subtype("_matter", "_tcp", op_node, self.hostname_wifi, subtype)
      end
    except .. as e, m
      tasmota.log("MTR: Exception" + str(e) + "|" + str(m), 2)
    end
  end
end
matter.Device = Matter_Device

#-
import global
global.matter_device = matter_device()
return matter_device
-#
