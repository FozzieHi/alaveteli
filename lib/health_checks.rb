require 'health_checks/health_checkable'

Dir[File.dirname(__FILE__) + '/health_checks/checks/*.rb'].each do |file|
  require file
end

module HealthChecks
  extend self

  def all
    @checks ||= []
  end

  def add(check)
    if assert_valid_check(check)
      all << check
      check
    else
      false
    end
  end

  def each(&block)
    all.each(&block)
  end

  def ok?
    all.all?(&:ok?)
  end

  private

  def assert_valid_check(check)
    check.respond_to?(:ok?)
  end

end
