# frozen_string_literal: true
require 'chef/provisioning'
require 'chef/provisioning/vsphere_driver/driver'

# The main Chef class for all the Chef code!
class Chef
  # The main Chef module for the Domain Specialized Language
  module DSL
    # The main Chef module for the the Recipe in side of Chef's DSL
    module Recipe
      # Creates the url object for Chef-Provisioning to leverage.
      #
      # @param [Object] driver_options Used from the Chef Provisioning to connect
      # @param [Object] block TODO
      def with_vsphere_driver(driver_options, &block)
        url = ChefProvisioningVsphere::VsphereDriver.canonicalize_url(
          nil, driver_options
        )[0]
        with_driver url, driver_options, &block
      end
    end
  end
end
