module DomainHelper
  def users(tlds)
    addresses = {}
    tlds.keys.each do |tld|
      next unless tlds[tld].has_key?('subdomains')
      tlds[tld]['subdomains'].keys.each do |subd|
        next unless tlds[tld]['subdomains'][subd].has_key?('addresses')
        tlds[tld]['subdomains'][subd]['addresses'].keys.each do |addr|
          user = tlds[tld]['subdomains'][subd]['addresses'][addr]
          if user.is_a?(Array)
            addresses[user.sort.join('_')] = user
          end
        end
      end
    end
    addresses
  end
end
