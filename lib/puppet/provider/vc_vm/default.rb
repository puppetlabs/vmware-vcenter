# Copyright (C) 2013 VMware, Inc.
provider_path = Pathname.new(__FILE__).parent.parent
require File.join(provider_path, 'vcenter')

Puppet::Type.type(:vc_vm).provide(:vc_vm, :parent => Puppet::Provider::Vcenter) do
  @doc = 'Manages vCenter Virtual Machines.'

  def exists?
    vm
  end

  def create
    if resource[:template]
      clone_vm
    else
      create_vm
    end
  #ensure
  #  raise(Puppet::Error, "Unable to create VM: '#{resource[:name]}'") unless vm
  end

  def destroy
    if power_state == 'poweredOn'
      Puppet.notice "Powering off VM #{resource[:name]} prior to removal."
      vm.PowerOffVM_Task.wait_for_completion
    else
      Puppet.debug "Virtual machine state: #{state}"
    end
    vm.Destroy_Task.wait_for_completion
  end

  # Method to create vm guestcustomization spec
  def getguestcustomization_spec(vm_adaptercount)
    host_name = RbVmomi::VIM.CustomizationFixedName(:name => resource[:name])

    case resource[:guest_type].to_s
    when 'windows'
      identity = windows_sysprep(host_name)
    when 'linux'
      identity = RbVmomi::VIM.CustomizationLinuxPrep(
        :domain => resource[:domain],
        :hostName => host_name,
        :timeZone => resource[:timezone]
      )
    end

    #Creating NIC specification
    nic_setting = get_nics(vm_adaptercount)

    RbVmomi::VIM.CustomizationSpec(
      :identity => identity,
      :globalIPSettings => RbVmomi::VIM.CustomizationGlobalIPSettings,
      :nicSettingMap=> nic_setting
    )
  end

  def windows_sysprep(computer_name)
    raise(Puppet::Error, 'Windows Product ID cannot be blank.') unless resource[:product_id]
    domain_admin = resource[:domain_admin]
    domain_admin_pass = resource[:domain_password]
    domain = resource[:domain]

    if domain_admin && domain_admin_pass && domain

      password = RbVmomi::VIM.CustomizationPassword(
        :plainText => true,
        :value     => domain_admin_pass
      )
      identification = RbVmomi::VIM.CustomizationIdentification(
        :domainAdmin         => domain_admin,
        :domainAdminPassword => password,
        :joinDomain          => domain
      )
    else
      identification = RbVmomi::VIM.CustomizationIdentification
    end

    admin_password = resource[:admin_password]

    timezone = resource[:timezone]
    autologon = resource[:autologon]
    autologon_count = resource[:autologon_count]

    if admin_password
      password =  RbVmomi::VIM.CustomizationPassword(
        :plainText => true,
        :value     => admin_password, 
      )
      gui_unattended = RbVmomi::VIM.CustomizationGuiUnattended(
        :autoLogon      => autologon,
        :autoLogonCount => autologon_count,
        :password       => password,
        :timeZone       => timezone
      )
    else
      gui_unattended = RbVmomi::VIM.CustomizationGuiUnattended(
        :autoLogon      => autologon,
        :autoLogonCount => autologon_count,
        :timeZone       => timezone
      )
    end

    user_data = RbVmomi::VIM.CustomizationUserData(
      :computerName => computer_name,
      :fullName     => resource[:full_name],
      :orgName      => resource[:org_name],
      :productId    => resource[:product_id]
    )

    license_mode = resource[:license_mode]
    mode = RbVmomi::VIM.CustomizationLicenseDataMode(license_mode);

    if license_mode.to_s = 'perServer'
      license = RbVmomi::VIM.CustomizationLicenseFilePrintData(
        :autoMode => mode,
        :autoUsers => resource[:license_users],
      )
    else
      license = RbVmomi::VIM.CustomizationLicenseFilePrintData(
        :autoMode => mode,
      )
    end

    RbVmomi::VIM.CustomizationSysprep(
      :guiUnattended => gui_unattended,
      :identification => identification, 
      :licenseFilePrintData => license,
      :userData => user_data
    )
  end

  # Get Nic Specification
  def get_nics(vm_adaptercount)
    cust_adapter_mapping_arr = nil
    customization_spec = nil
    nic_count = 0
    nic_spechash = resource[:nicspec]
    if nic_spechash
      nic_val = nic_spechash["nic"]

      if nic_val
        nic_count = nic_val.length
        if nic_count > 0
          count = 0
          nic_val.each_index {
            |index, val|

            if count > vm_adaptercount-1
              break
            end
            iparray = nic_val[index]
            cust_ip_settings = gvm_ipspec(iparray)

            cust_adapter_mapping = RbVmomi::VIM.CustomizationAdapterMapping(:adapter => cust_ip_settings )

            if count > 0
              cust_adapter_mapping_arr.push (cust_adapter_mapping)
            else
              cust_adapter_mapping_arr = Array [cust_adapter_mapping]
            end

            count = count + 1
          }
        end
      end
    end

    # Update the remaining adapters of with defaults settings.
    remaining_adapterscount = vm_adaptercount - nic_count

    if remaining_adapterscount > 0
      remaining_customization_fixed_ip = RbVmomi::VIM.CustomizationDhcpIpGenerator
      remaining_cust_ip_settings = RbVmomi::VIM.CustomizationIPSettings(:ip => remaining_customization_fixed_ip )
      remianing_cust_adapter_mapping = RbVmomi::VIM.CustomizationAdapterMapping(:adapter => remaining_cust_ip_settings )
      cust_adapter_mapping_arr.push (remianing_cust_adapter_mapping)
    end
    return cust_adapter_mapping_arr
  end

  # Guest VM IP spec
  def gvm_ipspec(iparray)

    ip_address = nil
    subnet = nil
    dnsserver = nil
    gateway = nil

    dnsserver_arr = []
    gateway_arr = []

    iparray.each_pair {
      |key, value|

      ip_address = value if key.eql?('ip')
      subnet = value if key.eql?('subnet')

      if key == "dnsserver"
        dnsserver = value
        dnsserver_arr.push (dnsserver)
      end

      if key == "gateway"
        gateway = value
        gateway_arr.push (gateway)
      end
    }

    if ip_address
      customization_fixed_ip = RbVmomi::VIM.CustomizationFixedIp(:ipAddress => ip_address)
    else
      customization_fixed_ip = RbVmomi::VIM.CustomizationDhcpIpGenerator
    end

    cust_ip_settings = RbVmomi::VIM.CustomizationIPSettings(:ip => customization_fixed_ip ,
    :subnetMask => subnet , :dnsServerList => dnsserver_arr , :gateway => gateway_arr,
    :dnsDomain => resource[:dnsdomain] )

    return cust_ip_settings

  end

  # Method to create VM relocate spec
  def createrelocate_spec
    dc = vim.serviceInstance.find_datacenter(resource[:datacenter])
    cluster_name = resource[:cluster]
    host_ip = resource[:host]
    target_datastore = resource[:datastore]

    checkfor_ds = "true"
    relocate_spec = nil
    if cluster_name and cluster_name.strip.length != 0
      relocate_spec = rs_cluster(dc,cluster_name)

    elsif host_ip and host_ip.strip.length != 0
      relocate_spec = rs_host(dc,host_ip)

    else
      checkfor_ds = "false"
      # Neither host not cluster name is provided. Getting the relocate specification
      # from VM view
      relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec
    end
    if checkfor_ds.eql?('true') and !relocate_spec.nil?
      relocate_spec = rs_datastore(dc,target_datastore,relocate_spec)
    end

    return relocate_spec
  end

  # Method to create vm relocate spec if cluster name is provided
  def rs_cluster(dc,cluster_name)
    cluster_relocate_spec = nil
    cluster ||= dc.find_compute_resource(cluster_name)
    if !cluster
      raise Puppet::Error, "Unable to find the cluster '#{cluster_name}' because the cluster is either invalid or does not exist."
    else
      cluster_relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(:pool => cluster.resourcePool)
    end
    return cluster_relocate_spec

  end

  # Method to update vm relocate spec if target datastore name is provided
  def rs_datastore(dc,target_datastore, relocate_spec)
    if target_datastore and target_datastore.strip.length != 0
      ds ||= dc.find_datastore(target_datastore)
      if !ds
        raise Puppet::Error, "Unable to find the target datastore '#{target_datastore}' because the target datastore is either invalid or does not exist."
        relocate_spec = nil
      else
        relocate_spec.datastore = ds
      end
    end
    return relocate_spec

  end

  # Method to create vm relocate spec if host ip is provided
  def rs_host(dc,host_ip)
    host_relocate_spec = nil

    host_view = vim.searchIndex.FindByIp(:datacenter => dc , :ip => host_ip, :vmSearch => false)

    if !host_view
      raise Puppet::Error, "Unable to find the host '#{host_ip}' because the host is either invalid or does not exist."
    else

      disk_format =  resource[:diskformat]
      updated_diskformat = "sparse"
      # Need to update updated_diskformat value if disk_format is set to thick
      updated_diskformat = "flat" if disk_format.eql?('thick')
      transform = RbVmomi::VIM.VirtualMachineRelocateTransformation(updated_diskformat);
      host_relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(:host => host_view, :pool => host_view.parent.resourcePool,
      :transform => transform)
    end
    return host_relocate_spec
  end


  def power_state(vm)
    vm.runtime.powerState
  end

  # Get the power state.
  def power_state
    Puppet.debug 'Retrieving the power state of the virtual machine.'
    @power_state = vm.runtime.powerState
  rescue Exception => e
    Puppet.err e.message
  end

  # Set the power state.
  def power_state=(value)
    Puppet.debug 'Setting the power state of the virtual machine.'

    case value
    when :poweredOff
      if (vm.guest.toolsStatus == 'toolsNotInstalled') or
        (vm.guest.toolsStatus == 'toolsNotRunning') or
        (resource[:graceful_shutdown] == :false)
        vm.PowerOffVM_Task.wait_for_completion unless power_state == 'poweredOff'
      else
        vm.ShutdownGuest
        # Since vm.ShutdownGuest doesn't return a task we need to poll the VM powerstate before returning.
        attempt = 5  # let's check 5 times (1 min 15 seconds) before we forcibly poweroff the VM.
        while power_state != 'poweredOff' and attempt > 0
          sleep 15
          attempt -= 1
        end
        vm.PowerOffVM_Task.wait_for_completion unless power_state == 'poweredOff'
      end
    when :poweredOn
      vm.PowerOnVM_Task.wait_for_completion
    when :suspended
      if @power_state == 'poweredOn'
        vm.SuspendVM_Task.wait_for_completion
      else
        raise(Puppet::Error, 'Unable to suspend the virtual machine unless in powered on state.')
      end
    when :reset
      if @power_state !~ /poweredOff|suspended/i
        vm.ResetVM_Task.wait_for_completion
      else
        raise(Puppet::Error, "Unable to reset the virtual machine because the system is in #{@power_state} state.")
      end
    end
  end

  # This method creates a new virtual machine,instead of cloning a virtual machine from an existing one.

  def create_vm
    datacenter = resource[:datacenter]
    dc = vim.serviceInstance.find_datacenter(datacenter)

    cluster_name = resource[:cluster]
    host_name = resource[:host]
    if cluster_name
      # Getting the pool information from cluster
      cluster = dc.find_compute_resource(cluster_name)
      raise(Puppet::Error, "Unable to find the cluster '#{cluster_name}'.") unless cluster
      resource_pool = cluster.resourcePool
      ds = cluster.datastore.first
    elsif host_name
      host = vim.searchIndex.FindByIp(:datacenter => dc , :ip => host_name, :vmSearch => false)
      raise(Puppet::Error, "Unable to find the host '#{host_name}'") unless host
      resource_pool = host.parent.resourcePool
      ds = host.datastore.first
    else
      raise(Puppet::Error, 'Must provider cluster or host for VM deployment')
    end

    raise(Puppet::Error, 'No datastores exist for the host') unless ds

    ds_path = "[#{ds.name}]"

    vm_devices = []
    vm_devices.push(scsi_controller_spec, disk_spec(ds_path))
    vm_devices.push(*network_specs)

    config_spec = RbVmomi::VIM.VirtualMachineConfigSpec({
      :name => resource[:name],
      :memoryMB => resource[:memory_mb],
      :numCPUs => resource[:num_cpus] ,
      :guestId => resource[:guestid],
      :files => { :vmPathName => ds_path },
      :memoryHotAddEnabled => resource[:memory_hot_add_enabled],
      :cpuHotAddEnabled => resource[:cpu_hot_add_enabled],
      :deviceChange => vm_devices
    })

    dc.vmFolder.CreateVM_Task(:config => config_spec, :pool => resource_pool).wait_for_completion
  
    # power_state= did not work.  
    self.send(:power_state=, resource[:power_state].to_sym)
  end

  def controller_map
    {
      'VMware Paravirtual' => :ParaVirtualSCSIController,
      'LSI Logic Parallel' => :VirtualLsiLogicController,
      'LSI Logic SAS' => :VirtualLsiLogicSASController,
      'BusLogic Parallel' => :VirtualBusLogicController,
    }
  end

  def scsi_controller_spec
    type = resource[:scsi_controller_type].to_s

    controller = RbVmomi::VIM.send(
      controller_map[type], 
      :key => 0,
      :device => [0],
      :busNumber => 0,
      :sharedBus => RbVmomi::VIM.VirtualSCSISharing('noSharing')
    )

    RbVmomi::VIM.VirtualDeviceConfigSpec(
      :device => controller,
      :operation => RbVmomi::VIM.VirtualDeviceConfigSpecOperation('add')
    )
  end

  #  create virtual device config spec for disk
  def disk_spec(file_name)
    thin = (resource[:disk_format].to_s == 'thin')

    backing = RbVmomi::VIM.VirtualDiskFlatVer2BackingInfo(
      :diskMode => 'persistent',
      :fileName => file_name,
      :thinProvisioned => thin
    )

    disk = RbVmomi::VIM.VirtualDisk(
      :backing => backing,
      :controllerKey => 0,
      :key => 0,
      :unitNumber => 0,
      :capacityInKB => resource[:disk_size]
    )

    RbVmomi::VIM.VirtualDeviceConfigSpec(
      :device => disk,
      :fileOperation => RbVmomi::VIM.VirtualDeviceConfigSpecFileOperation('create'),
      :operation => RbVmomi::VIM.VirtualDeviceConfigSpecOperation('add')
    )
  end

  # get network configuration
  def network_specs
    nics = []
    resource[:network_interfaces].each_with_index do |nic, index|
      portgroup = nic['portgroup']
      backing = RbVmomi::VIM.VirtualEthernetCardNetworkBackingInfo(:deviceName => portgroup)
      nic =  RbVmomi::VIM.send(
        "Virtual#{PuppetX::VMware::Util.camelize(nic['nic_type'])}".to_sym,
        {
          :key => index,
          :backing => backing,
          :deviceInfo => {
            :label => "Network Adapter",
            :summary => portgroup
          }
        }
      )
      nics << RbVmomi::VIM.VirtualDeviceConfigSpec(
        :device => nic,
        :operation => RbVmomi::VIM.VirtualDeviceConfigSpecOperation('add')
      )
    end
    nics
  end

  # This method creates a VMware Virtual Machine instance based on the specified base image
  # or the base image template name. The existing baseline Virtual Machine, must be available
  # on a shared data-store and must be visible on all ESX hosts. The Virtual Machine capacity
  # is allcoated based on the "numcpu" and "memorymb" parameter values, that are speicfied in the input file.
  def clone_vm
    dc_name = resource[:datacenter]
    goldvm_dc_name = resource[:goldvm_datacenter]
    vm_name = resource[:name]
    source_dc = vim.serviceInstance.find_datacenter(goldvm_dc_name)
    virtualmachine_obj = source_dc.find_vm(resource[:goldvm]) or abort "Unable to find Virtual Machine."
    goldvm_adapter = virtualmachine_obj.summary.config.numEthernetCards
    # Calling createrelocate_spec method
    relocate_spec = createrelocate_spec
    if relocate_spec.nil?
      raise Puppet::Error, "Unable to retrieve the specification required to relocate the Virtual Machine."
    end

    config_spec = RbVmomi::VIM.VirtualMachineConfigSpec(
      :name => vm_name,
      :memoryMB => resource[:memory_mb],
      :numCPUs => resource[:num_cpus]
    )

    guestcustomizationflag = resource[:guestcustomization]
    guestcustomizationflag = guestcustomizationflag.to_s

    if guestcustomizationflag.eql?('true')
      Puppet.notice "Customizing the guest OS."
      # Calling getguestcustomization_spec method in case guestcustomization
      # parameter is specified with value true
      customization_spec_info = getguestcustomization_spec ( goldvm_adapter )
      if customization_spec_info.nil?
        raise Puppet::Error, "Unable to retrieve the specification required for Virtual Machine customization."
      end
      spec = RbVmomi::VIM.VirtualMachineCloneSpec(
        :location => relocate_spec,
        :powerOn => (resource[:power_state] == :poweredOn),
        :template => false,
        :customization => customization_spec_info,
        :config => config_spec
      )
    else
      spec = RbVmomi::VIM.VirtualMachineCloneSpec(
        :location => relocate_spec,
        :powerOn => (resource[:power_state] == :poweredOn),
        :template => false,
        :config => config_spec
      )
    end

    dc = vim.serviceInstance.find_datacenter(dc_name)
    virtualmachine_obj.CloneVM_Task(
      :folder => dc.vmFolder,
      :name => vm_name,
      :spec => spec
    ).wait_for_completion
  end

  private

  def findvm(folder,vm_name)
    folder.children.each do |f|
      break if @vm_obj
      case f
      when RbVmomi::VIM::Folder
        findvm(f,vm_name)
      when RbVmomi::VIM::VirtualMachine
        @vm_obj = f if f.name == vm_name
      when RbVmomi::VIM::VirtualApp
        f.vm.each do |v|
          if v.name == vm_name
            @vm_obj = f
            break
          end
        end
      else
        Puppet.err
        "unknown child type found: #{f.class}"
        exit
      end
    end
    @vm_obj
  end

  def datacenter(name=resource[:datacenter])
    vim.serviceInstance.find_datacenter(name) or raise Puppet::Error, "datacenter '#{name}' not found."
  end

  def vm
    # findvm(datacenter.vmFolder,resource[:name])
    @vm ||= findvm(datacenter.vmFolder, resource[:name])
  end
  
  def network_interfaces
    resource['network_interfaces']
  end

end
