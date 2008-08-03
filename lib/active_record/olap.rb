module ActiveRecord::OLAP
  
  def enable_active_olap(config = nil, &block)

    self.class_eval { extend ClassMethods }
    self.named_scope :olap_drilldown, lambda { |hash| self.olap_drilldown_finder_options(hash) }    
    
    self.cattr_accessor :active_olap_dimensions, :active_olap_aggregates
    self.active_olap_dimensions = {}
    self.active_olap_aggregates = {}    
    
    if config.nil? && block_given?
      conf = Configurator.new(self)
      yield(conf) 
    end
    
  end
  
  
  module ClassMethods
    
    # Performs an OLAP query that counts how many records do occur in given categories.
    # It can be used for multiple dimensions 
    # It expects a list of category definitions
    def olap_query(*args)

      # set aggregates apart if they are given
      aggregates_given = (args.last.kind_of?(Hash) && args.last.has_key?(:aggregate)) ? args.pop[:aggregate] : nil
      
      # parse the dimensions
      raise "You have to provide at least one dimension for an OLAP query" if args.length == 0    
      dimensions = args.collect { |d| Dimension.create(self, d) }
      
      raise "Overlapping categories only supported in the last dimension" if dimensions[0..-2].any? { |d| d.has_overlap? }
      raise "Only counting is supported with overlapping categories" if dimensions.last.has_overlap? && aggregates_given

      if aggregates_given
        aggregates = Aggregate.all_from_olap_query_call(self, aggregates_given)
      elsif dimensions.last.has_overlap?
        aggregates = []
      else
        aggregates = [Aggregate.create(self, :the_olap_count_field, :count_distinct)]
      end

      conditions = self.send(:merge_conditions, *dimensions.map(&:conditions))
      joins = (dimensions.map(&:joins) + aggregates.map(&:joins)).flatten.uniq
      joins_clause = joins.empty? ? nil : joins.join(' ')


      selects = aggregates.map { |agg| agg.to_sanitized_sql }
      groups  = []

      if aggregates.length > 0
        dimensions_to_group = dimensions.clone
      else 
        selects << dimensions.last.to_aggregate_expression
        dimensions_to_group = dimensions[0, dimensions.length - 1]
      end
      
      dimensions_to_group.each_with_index do |d, index|
        var_name = "dimension_#{index}"
        groups  << self.connection.quote_column_name(var_name)
        selects << d.to_case_expression(var_name)
      end
    
      group_clause = groups.length > 0 ? groups.join(', ') : nil
      # TODO: having
      query_result = self.scoped(:conditions => conditions).find(:all, :select => selects.join(', '), 
          :joins => joins_clause, :group => group_clause, :order => group_clause)  

      return Cube.new(self, dimensions, aggregates, query_result)
    end   
  end
  
  protected
  
  def olap_drilldown_finder_options(options)
    raise "You have to provide at least one dimension for an OLAP query" if options.length == 0    

    # returns an options hash to create a scope (the named_scope :olap_drilldown)
    conditions = options.map { |dim, cat| Dimension.create(self, dim).sanitized_sql_for(cat) }
    { :select => connection.quote_table_name(table_name) + '.*', :conditions => self.send(:merge_conditions, *conditions) }
  end
  
end