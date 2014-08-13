require 'open-uri'
require "rails_admin_import/import_logger"
  
module RailsAdminImport
  module Import
    extend ActiveSupport::Concern
  
    module ClassMethods
      def import_config
        @import_config ||= RailsAdminImport.config(self)
      end
      
      def file_fields
        if self.methods.include?(:attachment_definitions) && !self.attachment_definitions.nil?
          attrs = self.attachment_definitions.keys
        else
          attrs = []
        end
        
        attrs - import_config.excluded_fields
      end
  
      def import_fields
        fields = []
        
        if import_config.included_fields.any?
          fields = import_config.included_fields.dup
        else
          if respond_to?(:fields)
            fields = self.fields.keys.map(&:to_sym).reject { |f| [:_id, :id, :c_at, :u_at, :created_at, :updated_at].include?(f) }
          else
            fields = self.new.attributes.keys.map(&:to_sym)
          end
        end
        
        self.belongs_to_fields.each do |key|
          fields.delete(key)
          fields.delete("#{key}_id".to_sym)
        end
        
        self.file_fields.each do |key|
          fields.delete("#{key}_file_name".to_sym)
          fields.delete("#{key}_content_type".to_sym)
          fields.delete("#{key}_file_size".to_sym)
          fields.delete("#{key}_updated_at".to_sym)
        end
        
        [:id, :created_at, :updated_at, import_config.excluded_fields].flatten.each do |key|
          fields.delete(key)
        end
        
        fields
      end
 
      def belongs_to_fields(klass = self)
        attrs = get_relations.select{|k, v| [:belongs_to, :embedded_in].include?(v.macro) }.keys.collect(&:to_sym)
        attrs.reject { |attr| import_config.included_fields.include?(attr) }
      end
  
      def many_fields
        associations  = [:has_and_belongs_to_many, :has_many, :embeds_many]
        attrs         = get_relations.select{|k, v| associations.include?(v.macro) }.keys.collect(&:to_sym)
        attrs.reject { |attr| import_config.included_fields.include?(attr) }
      end
      
      def get_relations
        # handle Mongoid or ActiveRecord
        self.respond_to?(:relations) ? relations : reflections
      end

      def get_model_for(field)
        get_relations[field.to_s].class_name.constantize
      end
  
      def run_import(params)
        logger = Rails.logger
        
        # begin
          if !params.has_key?(:file)
            return results = { :success => [], :error => ["You must select a file."] }
          end

          if RailsAdminImport.config.logging
            FileUtils.copy(params[:file].tempfile, "#{Rails.root}/log/import/#{Time.now.strftime("%Y-%m-%d-%H-%M-%S")}-import.csv")
          end

          text        = File.read(params[:file].tempfile)
          clean       = text.force_encoding('BINARY').encode('UTF-8', :undef => :replace, :replace => '').gsub(/\n$/, '')
          file_check  = CSV.new(clean)
          logger      = ImportLogger.new
     
          if file_check.readlines.size > RailsAdminImport.config.line_item_limit
            return results = { :success => [], :error => ["Please limit upload file to #{RailsAdminImport.config.line_item_limit} line items."] }
          end
  
          map   = {}
          file  = CSV.new(clean)
          
          file.readline.each_with_index do |key, i|
            next if key.nil?

            if self.many_fields.include?(key.to_sym)
              map[key.to_sym] ||= []
              map[key.to_sym] << i
            else
              map[key.to_sym] = i 
            end
          end
          
          update = params.has_key?(:update_if_exists) && params[:update_if_exists] ? params[:update_lookup].to_sym : nil
          if update && !map.has_key?(params[:update_lookup].to_sym)
            return results = { :success => [], :error => ["Your file must contain a column for the 'Update lookup field' you selected."] }
          end 
    
          results = { :success => [], :error => [] }
          associated_map = {}
          
          self.belongs_to_fields.flatten.each do |field|
            model = get_model_for(field)
            associated_map[field] = model.all.inject({}) do |hash, c|
              hash[c.send(params[field]).to_s] = c.id
              hash
            end
          end
          
          self.many_fields.flatten.each do |field|
            model = get_model_for(field)
            associated_map[field] = model.all.inject({}) do |hash, c|
              hash[c.send(params[field]).to_s] = c
              hash
            end
          end
   
          label_method        = import_config.label
          before_import_save  = import_config.before_import_save
          
          # handle nesting in parent object
          unless import_config.create_parent.nil?
            parent_object = import_config.create_parent.call()
            nested_field  = import_config.nested_field
          end
          
          file.each do |row|
            object = self.import_initialize(row, map, update)
            object.import_belongs_to_data(associated_map, row, map)
            object.import_many_data(associated_map, row, map)
            object.before_import_save(row, map)
            object.import_files(row, map)
            
            if before_import_save
              before_import_save_args = [object, row, map, role, current_user]
              before_import_save_args << parent_object if parent_object
              
              callback_result         = before_import_save.call(*before_import_save_args)
              skip_nested_save        = callback_result == false && !parent_object.nil?
            end
            
            object.import_files(row, map)
            
            if parent_object
              parent_object.send(nested_field) << object
            end
            
            verb = object.new_record? ? "Create" : "Update"

            if object.errors.empty?
              if skip_nested_save
                logger.info "#{Time.now.to_s}: Skipped nested save: #{object.send(label_method)}"
                results[:success] << "Skipped nested save: #{object.send(label_method)}"
              elsif object.save
                logger.info "#{Time.now.to_s}: #{verb}d: #{object.send(label_method)}"
                results[:success] << "#{verb}d: #{object.send(label_method)}"
                object.after_import_save(row, map)
              else
                logger.info "#{Time.now.to_s}: Failed to #{verb.downcase}: #{object.send(label_method)}. Errors: #{object.errors.full_messages.join(', ')}."
                results[:error] << "Failed to #{verb.downcase}: #{object.send(label_method)}. Errors: #{object.errors.full_messages.join(', ')}."
              end
            else
              logger.info "#{Time.now.to_s}: Errors before save: #{object.send(label_method)}. Errors: #{object.errors.full_messages.join(', ')}."
              results[:error] << "Errors before save: #{object.send(label_method)}. Errors: #{object.errors.full_messages.join(', ')}."
            end
          end
          
          if parent_object
            import_config.before_parent_save.call(parent_object, role, current_user) if import_config.before_parent_save
            
            if parent_object.save
              logger.info "#{Time.now.to_s}: Saved #{parent_object.class.name}"
              results[:success].unshift "Saved: #{parent_object}"
            else
              logger.info "#{Time.now.to_s}: Failed to save #{parent_object.class.name}. Errors: #{parent_object.errors.full_messages.join(', ')}."
              results[:error].unshift "Failed to save #{parent_object.class.name}. Errors: #{parent_object.errors.full_messages.join(', ')}."
            end
            
            import_config.after_parent_save.call(parent_object, role, current_user) if import_config.after_parent_save
            
          end
          
          import_config.after_import.call(results) if import_config.after_import
    
          results
        # rescue Exception => e
          # logger.info "#{Time.now.to_s}: Unknown exception in import: #{e.inspect}"
          # return results = { :success => [], :error => ["Could not upload. Unexpected error: #{e.to_s}"] }
        # end
      end
  
      def import_initialize(row, map, update)
        new_attrs = {}
        self.import_fields.each do |key|
          new_attrs[key] = row[map[key]] if map[key]
        end

        item = nil
        if update.present?
          item = self.send("find_by_#{update}", row[map[update]])
        end 

        if item.nil?
          item = self.new(new_attrs)
        else
          item.attributes = new_attrs.except(update.to_sym)
          item.save
        end

        item
      end
    end
   
    def before_import_save(*args)
      # Meant to be overridden to do special actions
    end

    def after_import_save(*args)
      # Meant to be overridden to do special actions
    end

    def import_display
      self.id
    end

    def import_files(row, map)
      if self.new_record? && self.valid?
        self.class.file_fields.each do |key|
          if map[key] && !row[map[key]].nil?
            begin
              # Strip file
              row[map[key]] = row[map[key]].gsub(/\s+/, "")
              format = row[map[key]].match(/[a-z0-9]+$/)
              open("#{Rails.root}/tmp/#{self.permalink}.#{format}", 'wb') { |file| file << open(row[map[key]]).read }
              self.send("#{key}=", File.open("#{Rails.root}/tmp/#{self.permalink}.#{format}"))
            rescue Exception => e
              self.errors.add(:base, "Import error: #{e.inspect}")
            end
          end
        end
      end
    end

    def import_belongs_to_data(associated_map, row, map)
      self.class.belongs_to_fields.each do |key|
        if map.has_key?(key) && row[map[key]] != ""
          self.send("#{key}_id=", associated_map[key][row[map[key]]])
        end
      end
    end

    def import_many_data(associated_map, row, map)
      self.class.many_fields.each do |key|
        values = []

        map[key] ||= []
        map[key].each do |pos|
          if row[pos] != "" && associated_map[key][row[pos]]
            values << associated_map[key][row[pos]]
          end
        end

        if values.any?
          self.send("#{key.to_s.pluralize}=", values)
        end
      end
    end
  end
end

if defined? ActiveRecord::Base
  class ActiveRecord::Base
    include RailsAdminImport::Import
  end
end
