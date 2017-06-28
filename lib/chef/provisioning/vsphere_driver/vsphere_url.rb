# frozen_string_literal: false
require 'uri'

# The main URI Module
module URI
  # Creates the vSphereURL, extended by the Generic Class
  class VsphereUrl < Generic
    # Default port for connecting to the vSphere cluster Webserver
    DEFAULT_PORT = 443
    # Default path for connecting to the vSphere cluster URL
    DEFAULT_PATH = '/sdk'.freeze

    # Creates the URL from options that are decided
    #
    def self.from_config(options)
      parts = []
      parts << 'vsphere://'
      parts << options[:host]
      parts << ':'
      parts << (options[:port] || DEFAULT_PORT)
      parts << (options[:path] || DEFAULT_PATH)
      parts << '?use_ssl='
      parts << (options[:use_ssl] == false ? false : true)
      parts << '&insecure='
      parts << (options[:insecure] || false)
      URI parts.join
    end

    # Converts URL to SSL if needed
    #
    def use_ssl
      if query
        ssl_query = query.split('&').each.select do |q|
          q.start_with?('use_ssl=')
        end.first
        ssl_query == 'use_ssl=true'
      else
        true
      end
    end

    # Converts URL to insecure if needed
    #
    def insecure
      if query
        insecure_query = query.split('&').each.select do |q|
          q.start_with?('insecure=')
        end.first
        insecure_query == 'insecure=true'
      else
        false
      end
    end
  end
  @@schemes['VSPHERE'] = VsphereUrl
end
