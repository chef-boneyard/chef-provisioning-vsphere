# frozen_string_literal: true
require 'chef/provisioning/driver'

# Provisions machines in vSphere.
module ChefProvisioningVsphere
  # Helps save data in provisioning a machine
  class VmHelper
    attr_accessor :ip, :port

    # An array of all the known EXCEPTIONS for connecting via Chef-Provisioning-vSphere
    RESCUE_EXCEPTIONS_ON_ESTABLISH = [
      Errno::EACCES, Errno::EADDRINUSE, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
      Errno::ECONNRESET, Errno::ENETUNREACH, Errno::EHOSTUNREACH, Errno::EPIPE,
      Errno::EPERM, Errno::EFAULT, Errno::EIO, Errno::EHOSTDOWN,
      Net::SSH::Disconnect, Net::SSH::AuthenticationFailed, Net::SSH::ConnectionTimeout,
      Timeout::Error, IPAddr::AddressFamilyError
    ].freeze

    # If the IP is true
    #
    def ip?
      @ip
    end

    # If the port is true
    #
    def port?
      @port
    end

    # Finds the port for to connect to the vm
    #
    # @param [Object] vm Uses the VM object from Chef provisioning.
    # @param [Hash] options Uses the VM options from Chef provisioning.
    # @return [true] The port to connect to the VM whether Windows or *nix.
    def find_port?(vm, options)
      @port = options[:ssh][:port]
      customization_spec = options[:customization_spec]
      if vm.config.guestId.start_with?('win')
        if customization_spec.is_a?(Hash)
          winrm_transport =
            customization_spec[:winrm_transport].nil? ? :negotiate : customization_spec[:winrm_transport].to_sym
        end
        winrm_transport ||= :negotiate
        default_win_port = winrm_transport == :ssl ? '5986' : '5985'
        @port = default_win_port if @port.nil?
      elsif port.nil?
        @port = '22'
      end
      true
    end

    # Attempt to connects to the open port
    #
    # @param [String] host Uses the host string to connect.
    # @param [String] port Uses the port number to connect.
    # @param [Integer] timeout The number of seconds before timeout.
    # @return [true] Returns true when the socket is available to connect.
    def open_port?(host, port, timeout = 5)
      return false if host.to_s.empty?
      true if ::Socket.tcp(host, port, connect_timeout: timeout)
    rescue *RESCUE_EXCEPTIONS_ON_ESTABLISH
      false
    end
  end
end
