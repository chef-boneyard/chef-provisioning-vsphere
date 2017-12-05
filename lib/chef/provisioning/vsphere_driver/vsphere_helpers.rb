# frozen_string_literal: true

require 'rbvmomi'
require 'uri'
require 'net/http'

# Provisions machines in vSphere.
module ChefProvisioningVsphere
  # A namespace to use for vSphere Helpers
  class VsphereHelper
    $guest_op_managers = {} unless $guest_op_managers

    def initialize(connect_options, datacenter_name)
      http = Net::HTTP.new(connect_options[:host], connect_options[:port])
      if http.proxy?
        connect_options[:proxyHost] = http.proxy_address
        connect_options[:proxyPort] = http.proxy_port
      end
      @connect_options = connect_options
      @datacenter_name = datacenter_name
    end

    attr_reader :connect_options
    attr_reader :datacenter_name

    # Establishes the connection to the vSphere cluster
    #
    def vim
      if @current_connection.nil? || @current_connection.serviceContent.sessionManager.currentSession.nil?
        @datacenter = nil
        puts "establishing connection to #{connect_options[:host]}"
        @current_connection = RbVmomi::VIM.connect connect_options
        str_conn = @current_connection.pretty_inspect # a string in the format of VIM(host ip)

        # we are caching guest operation managers in a global variable...terrible i know
        # this object is available from the serviceContent object on API version 5 forward
        # Its a singleton and if another connection is made for the same host and user
        # that object is not available on any subsequent connection
        # I could find no documentation that discusses this
        unless $guest_op_managers.key?(str_conn)
          $guest_op_managers[str_conn] = @current_connection.serviceContent.guestOperationsManager
        end
      end

      @current_connection
    end

    # Finds the vm using RbVmomi
    #
    # @param [String] folder the folder name for to look into.
    # @param [String] vm_name the name of the machine.
    def find_vm(folder, vm_name)
      folder = find_folder(folder) unless folder.is_a? RbVmomi::VIM::Folder
      folder.find(vm_name, RbVmomi::VIM::VirtualMachine)
    end

    # Finds the vm using the UUID
    #
    # @param [String] uuid the UUID of the machine
    def find_vm_by_id(uuid)
      vm = vim.searchIndex.FindByUuid(
        uuid: uuid,
        vmSearch: true,
        instanceUuid: true
      )
    end

    # Starts the VM
    #
    # @param [Object] vm the main VM object to talk to vSphere.
    # @param [Object] _wait_on_port Defaults to port 22, to connect and verify it's up.
    def start_vm(vm, _wait_on_port = 22)
      state = vm.runtime.powerState
      vm.PowerOnVM_Task.wait_for_completion unless state == 'poweredOn'
    end

    # Stops the VM
    #
    # @param [Object] vm the main VM object to talk to vSphere.
    # @param [Object] timeout Defaults to 600 seconds or 10 mins before giving up.
    def stop_vm(vm, timeout = 600)
      start = Time.now.utc
      return if vm.runtime.powerState == 'poweredOff'
      begin
        vm.ShutdownGuest
        until (Time.now.utc - start) > timeout ||
              vm.runtime.powerState == 'poweredOff'
          print '.'
          sleep 2
        end
      rescue
        vm.PowerOffVM_Task.wait_for_completion
      end
    end

    # Find the folder it could be like:  /Level1/Level2/folder_name
    #
    # @param [String] folder_name the name of the folder.
    # @return [Object] base the location of the folder.
    def find_folder(folder_name)
      base = datacenter.vmFolder
      unless folder_name.nil?
        folder_name.split('/').reject(&:empty?).each do |item|
          base = base.find(item, RbVmomi::VIM::Folder) ||
                 raise("vSphere Folder not found [#{folder_name}]")
        end
      end
      base
    end

    # Walks through the folders to if needed
    #
    # @param [String] folder the name of the folder.
    # @param [String] dcname the name of the DC.
    # @return [False] Returns false if not needed.
    def traverse_folders_for_dc(folder, dcname)
      children = folder.children.find_all
      children.each do |child|
        if child.class == RbVmomi::VIM::Datacenter && child.name == dcname
          return child
        elsif child.class == RbVmomi::VIM::Folder
          dc = traverse_folders_for_dc(child, dcname)
          return dc if dc
        end
      end
      false
    end

    # Connects to the Datacenter and creates Object
    #
    # @return [Object] Creates the dc object to know where to create the VMs.
    def datacenter
      vim # ensure connection is valid
      @datacenter ||= begin
        rootFolder = vim.serviceInstance.content.rootFolder
        dc = traverse_folders_for_dc(vim.rootFolder, datacenter_name) || abort('vSphere Datacenter not found [#{datacenter_name}]')
      end
    end

    # Creates the network adapter for Rbvmomi
    #
    # @param [Object] operation what you need to do to RBvmomi
    # @param [String] network_name the name of the network the adapter needs to connect to
    # @param [String] network_label the more verbose name of the network the adapter needs to connect to
    # @param [String] device_key TODO
    # @param [String] backing_info TODO
    def network_adapter_for(operation, network_name, network_label, device_key, backing_info)
      connectable = RbVmomi::VIM::VirtualDeviceConnectInfo(
        allowGuestControl: true,
        connected: true,
        startConnected: true
      )
      device = RbVmomi::VIM::VirtualVmxnet3(
        backing: backing_info,
        deviceInfo: RbVmomi::VIM::Description(label: network_label, summary: network_name.split('/').last),
        key: device_key,
        connectable: connectable
      )
      RbVmomi::VIM::VirtualDeviceConfigSpec(
        operation: operation,
        device: device
      )
    end

    # Finds the Network cards from the VM
    #
    # @param [Object] vm the VM object to do the query against.
    def find_ethernet_cards_for(vm)
      vm.config.hardware.device.select { |d| d.is_a?(RbVmomi::VIM::VirtualEthernetCard) }
    end

    # Add another NIC to the VM
    #
    # @param [Object] action_handler TODO
    # @param [String] vm_template the Name of the Template to clone
    # @param [Object] options the options from Chef Provisioning to help configure the VM.
    # @param [Object] vm the actual VM object to connect the VM to.
    def add_extra_nic(action_handler, vm_template, options, vm)
      deviceAdditions, changes = network_device_changes(action_handler, vm_template, options)

      if deviceAdditions.count.positive?
        current_networks = find_ethernet_cards_for(vm).map { |card| network_id_for(card.backing) }
        new_devices = deviceAdditions.reject { |device| current_networks.include?(network_id_for(device.device.backing)) }

        if new_devices.count.positive?
          action_handler.report_progress 'Adding extra NICs'
          task = vm.ReconfigVM_Task(spec: RbVmomi::VIM.VirtualMachineConfigSpec(deviceChange: new_devices))
          task.wait_for_completion
          new_devices
        end
      end
    end

    # Gets the network id for a specific thing?
    #
    # @param [String] backing_info TODO
    def network_id_for(backing_info)
      if backing_info.is_a?(RbVmomi::VIM::VirtualEthernetCardDistributedVirtualPortBackingInfo)
        backing_info.port.portgroupKey
      else
        backing_info.deviceName
      end
    end

    # Creates a delta disk for a vm template
    #
    # @param [String] vm_template the Name of the Template to clone.
    def create_delta_disk(vm_template)
      disks = vm_template.config.hardware.device.grep(RbVmomi::VIM::VirtualDisk)
      disks.select { |disk| disk.backing.parent.nil? }.each do |disk|
        spec = {
          deviceChange: [
            {
              operation: :remove,
              device: disk
            },
            {
              operation: :add,
              fileOperation: :create,
              device: disk.dup.tap do |new_disk|
                new_disk.backing = new_disk.backing.dup
                new_disk.backing.fileName = "[#{disk.backing.datastore.name}]"
                new_disk.backing.parent = disk.backing
              end
            }
          ]
        }
        vm_template.ReconfigVM_Task(spec: spec).wait_for_completion
      end
    end

    # Creates a virtual disk for the VM
    #
    # @param [Object] vm the VM object.
    # @param [Subject] datastore the datastore the disk will be created on.
    # @param [Subject] size_gb the size of the disk.
    def virtual_disk_for(vm, datastore, size_gb)
      idx = vm.disks.count
      RbVmomi::VIM::VirtualDeviceConfigSpec(
        operation: :add,
        fileOperation: :create,
        device: RbVmomi::VIM.VirtualDisk(
          key: idx,
          backing: RbVmomi::VIM.VirtualDiskFlatVer2BackingInfo(
            fileName: "[#{datastore}]",
            diskMode: 'persistent',
            thinProvisioned: true
          ),
          capacityInKB: size_gb * 1024 * 1024,
          controllerKey: 1000,
          unitNumber: idx
        )
      )
    end

    # Creates the additional virtual disk for the VM
    #
    # @param [Object] vm the VM object.
    # @param [Subject] datastore the datastore the disk will be created on.
    # @param [Subject] size_gb the size of the disk.
    def set_additional_disks_for(vm, datastore, additional_disk_size_gb)
      (additional_disk_size_gb.is_a?(Array) ? additional_disk_size_gb : [additional_disk_size_gb]).each do |size|
        size = size.to_i
        next if size.zero?
        if datastore.to_s.empty?
          raise ':datastore must be specified when adding a disk to a cloned vm'
        end
        task = vm.ReconfigVM_Task(
          spec: RbVmomi::VIM.VirtualMachineConfigSpec(
            deviceChange: [
              virtual_disk_for(
                vm,
                datastore,
                size
              )
            ]
          )
        )
        task.wait_for_completion
      end
    end

    # Updates the main virtual disk for the VM
    # This can only add capacity to the main disk, it is not possible to reduce the capacity.
    #
    # @param [Object] vm the VM object.
    # @param [Subject] size_gb the final size of the disk.
    def update_main_disk_size_for(vm, size_gb)
      disk = vm.disks.first
      size_kb = size_gb.to_i * 1024 * 1024
      if disk.capacityInKB > size_kb
        if size_gb.to_i > 0
          msg = "Specified disk size #{size_gb}GB is inferior to the template's disk size (#{disk.capacityInKB / 1024**2}GB)."
          msg += "\nThe VM disk size will remain the same."
          Chef::Log.warn(msg)
        end
        return false
      end
      disk.capacityInKB = size_kb
      vm.ReconfigVM_Task(
        spec: RbVmomi::VIM.VirtualMachineConfigSpec(
          deviceChange: [
            {
              operation: :edit,
              device: disk
            }
          ]
        )
      ).wait_for_completion
    end

    # Add a new network card via the boot_options
    #
    # @param [Object] action_handler TODO
    # @param [String] vm_template the Name of the Template to clone
    # @param [Object] options the options from Chef Provisioning to help configure the VM.
    def network_device_changes(action_handler, vm_template, options)
      additions = []
      changes = []
      networks = options[:network_name]
      networks = [networks] if networks.is_a?(String)

      cards = find_ethernet_cards_for(vm_template)

      key = 4000
      networks.each_index do |i|
        label = "Ethernet #{i + 1}"
        backing_info = backing_info_for(action_handler, networks[i])
        if card = cards.shift
          key = card.key
          operation = RbVmomi::VIM::VirtualDeviceConfigSpecOperation('edit')
          action_handler.report_progress "changing template nic for #{networks[i]}"
          changes.push(
            network_adapter_for(operation, networks[i], label, key, backing_info)
          )
        else
          key += 1
          operation = RbVmomi::VIM::VirtualDeviceConfigSpecOperation('add')
          action_handler.report_progress "will be adding nic for #{networks[i]}"
          additions.push(
            network_adapter_for(operation, networks[i], label, key, backing_info)
          )
        end
      end
      [additions, changes]
    end

    # Discover and identity network names
    #
    # @param [Object] action_handler TODO
    # @param [String] network_name The network name to attach to
    def backing_info_for(action_handler, network_name)
      action_handler.report_progress('finding networks...')
      network = find_network(network_name)
      action_handler.report_progress(
        "network: #{network_name} is a #{network.class}"
      )
      if network.is_a?(RbVmomi::VIM::DistributedVirtualPortgroup)
        port = RbVmomi::VIM::DistributedVirtualSwitchPortConnection(
          switchUuid: network.config.distributedVirtualSwitch.uuid,
          portgroupKey: network.key
        )
        RbVmomi::VIM::VirtualEthernetCardDistributedVirtualPortBackingInfo(
          port: port
        )
      else
        RbVmomi::VIM::VirtualEthernetCardNetworkBackingInfo(
          deviceName: network_name.split('/').last
        )
      end
    end

    # Find the datastore name.
    #
    # @param [String] datastore_name The datastore name.
    def find_datastore(datastore_name)
      datacenter.datastore.find { |f| f.info.name == datastore_name } || raise("no such datastore #{datastore_name}")
    end

    # Locate the object/vm/whatever in the vSphere cluster
    #
    # @param [String] name The name of the "thing."
    # @param [String] parent_folder The name of the folder to start from.
    def find_entity(name, parent_folder)
      parts = name.split('/').reject(&:empty?)
      parts.each do |item|
        Chef::Log.debug("Identifying entity part: #{item} in folder type: #{parent_folder.class}")
        if parent_folder.is_a? RbVmomi::VIM::Folder
          Chef::Log.debug('Parent folder is a folder')
          parent_folder = parent_folder.childEntity.find { |f| f.name == item }
        else
          parent_folder = yield(parent_folder, item)
        end
      end
      parent_folder
    end

    # Find the (ESXi) host.
    #
    # @param [String] host_name Name of the (ESXi) VM host.
    def find_host(host_name)
      host = find_entity(host_name, datacenter.hostFolder) do |parent, part|
        case parent
        when RbVmomi::VIM::ClusterComputeResource || RbVmomi::VIM::ComputeResource
          parent.host.find { |f| f.name == part }
        when RbVmomi::VIM::HostSystem
          parent.host.find { |f| f.name == part }
        end
      end

      raise "vSphere Host not found [#{host_name}]" if host.nil?

      host = host.host.first if host.is_a?(RbVmomi::VIM::ComputeResource)
      host
    end

    # Find the Resource pool.
    #
    # @param [String] pool_name Name of the Resource Pool.
    def find_pool(pool_name)
      Chef::Log.debug("Finding pool: #{pool_name}")
      pool = find_entity(pool_name, datacenter.hostFolder) do |parent, part|
        case parent
        when RbVmomi::VIM::ClusterComputeResource, RbVmomi::VIM::ComputeResource
          Chef::Log.debug("finding #{part} in a #{parent.class}: #{parent.name}")
          Chef::Log.debug("Parent root pool has #{parent.resourcePool.resourcePool.count} pools")
          parent.resourcePool.resourcePool.each { |p| Chef::Log.debug(p.name) }
          parent.resourcePool.resourcePool.find { |f| f.name == part }
        when RbVmomi::VIM::ResourcePool
          Chef::Log.debug("finding #{part} in a Resource Pool: #{parent.name}")
          Chef::Log.debug("Pool has #{parent.resourcePool.count} pools")
          parent.resourcePool.each { |p| Chef::Log.debug(p.name) }
          parent.resourcePool.find { |f| f.name == part }
        else
          Chef::Log.debug("parent of #{part} is unexpected type: #{parent.class}")
          nil
        end
      end

      raise "vSphere ResourcePool not found [#{pool_name}]" if pool.nil?

      if !pool.is_a?(RbVmomi::VIM::ResourcePool) && pool.respond_to?(:resourcePool)
        pool = pool.resourcePool
      end
      pool
    end

    # Find the Network name.
    #
    # @param [String] name Name of the Network.
    def find_network(name)
      base = datacenter.networkFolder
      entity_array = name.split('/').reject(&:empty?)
      entity_array.each do |item|
        base = traverse_folders_for_network(base, item)
      end

      raise "vSphere Network not found [#{name}]" if base.nil?

      base
    end

    # Search the item through the base's children
    # @param base vSphere object where to search
    # @param [String] item the name of the network to look for
    def traverse_folders_for_network(base, item)
      Chef::Log.debug("Searching #{item} in #{base.name}")
      case base
      when RbVmomi::VIM::Folder
        res = base.find(item)
        return res unless res.nil?
        base.childEntity.each do |child|
          res = traverse_folders_for_network(child, item)
          return res unless res.nil?
        end
        nil
      when RbVmomi::VIM::VmwareDistributedVirtualSwitch
        idx = base.summary.portgroupName.find_index(item)
        idx.nil? ? nil : base.portgroup[idx]
      end
    end

    # Locate the Customization Spec in vSphere.
    #
    # @param [String] customization_spec The name of the Customization Spec.
    def find_customization_spec(customization_spec)
      csm = vim.serviceContent.customizationSpecManager
      csi = csm.GetCustomizationSpec(name: customization_spec)
      spec = csi.spec
      raise "Customization Spec not found [#{customization_spec}]" if spec.nil?
      spec
    end

    # Upload a file to the VM using RbVmomi
    #
    # @param [Object] vm The VM object.
    # @param [String] username The username to access the machine.
    # @param [String] password The password to access the machine.
    # @param [String] local The local file to upload.
    # @param [String] remote The remote file to upload location.
    def upload_file_to_vm(vm, username, password, local, remote)
      auth = RbVmomi::VIM::NamePasswordAuthentication(username: username, password: password, interactiveSession: false)
      size = File.size(local)
      endpoint = $guest_op_managers[vim.pretty_inspect].fileManager.InitiateFileTransferToGuest(
        vm: vm,
        auth: auth,
        guestFilePath: remote,
        overwrite: true,
        fileAttributes: RbVmomi::VIM::GuestWindowsFileAttributes.new,
        fileSize: size
      )

      uri = URI.parse(endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      req = Net::HTTP::Put.new("#{uri.path}?#{uri.query}")
      req.body_stream = File.open(local)
      req['Content-Type'] = 'application/octet-stream'
      req['Content-Length'] = size
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        raise "Error: #{res.inspect} :: #{res.body} :: sending #{local} to #{remote} at #{vm.name} via #{endpoint} with a size of #{size}"
      end
    end
  end
end
