module Sphinx::Integration
  class Transmitter
    PRIMARY_KEY = "sphinx_internal_id".freeze
    TEMPLATE_ID = '%{ID}'.freeze

    attr_reader :klass

    class_attribute :write_disabled

    def initialize(klass)
      @klass = klass
    end

    # Обновляет записи в сфинксе
    #
    # records - Array
    #
    # Returns boolean
    def replace(records)
      return false if write_disabled?

      records = Array.wrap(records)

      rt_indexes.each do |index|
        transmit(index, records)
      end

      true
    end

    # Удаляет запись из сфинкса
    #
    # record - ActiveRecord::Base
    #
    # Returns boolean
    def delete(record)
      return false if write_disabled?

      rt_indexes.each do |index|
        index.rt.delete(record.sphinx_document_id)
        index.plain.soft_delete(record.sphinx_document_id)
      end

      true
    end

    # Обновление отдельных атрибутов записи
    #
    # record  - ActiveRecord::Base
    # data    - Hash (:field => :value)
    #
    # Returns nothing
    def update(record, data)
      return if write_disabled?

      update_fields(data, id: record.sphinx_document_id)
    end

    # Обновление отдельных атрибутов индекса по условию
    #
    # Массовое обновление колонок, при работающей полной переиндексации работает по следующей схеме.
    # Во время индексации запросы записываются в лог. После переиндексации
    # все эти обновления выполнятся вновь. То есть возможна временная недоуступность
    # новых данных (максимум пару минут). Это связано с тем, что indexer ротирует core индексы,
    # тем самым в core могут быть старые значения, а в rt обновляемых строк и вовсе не было.
    #
    # data      - Hash
    # :matching - NilClass or String or Hash of [Symbol, String]
    # where     - Hash
    #
    # Returns nothing
    def update_fields(data, matching: nil, **where)
      return if write_disabled?

      rt_indexes.each do |index|
        if index.indexing?
          # Вначале обновим все что уже есть в rt.
          index.rt.update(data, matching: matching, where: where)
          # Обновим всё в core и этот запрос запишется в query log, который потом повторится после ротации.
          index.plain.update(data, matching: matching, where: where)
        else
          index.distributed.update(data, matching: matching, where: where)
        end
      end
    end

    private

    # Запись объектов в rt index
    #
    # index  - ThinkingSphinx::Index
    # records - Array
    #
    # Returns nothing
    def transmit(index, records)
      data = transmitted_data(index, records)
      return unless data

      index.rt.replace(data)
      index.plain.soft_delete(records.map(&:sphinx_document_id))
    end

    def transmit_all(index, ids)
      records = klass.where(id: ids)
      transmit(index, records)
    end

    # Перекладывает строчки из core в rt.
    #
    # index     - ThinkingSphinx::Index
    # :matching - String
    # where     - Hash
    #
    # Returns nothing
    def retransmit(index, matching: nil, where: {})
      index.plain.find_while_exists(PRIMARY_KEY, matching: matching, where: where) do |rows|
        ids = rows.map { |row| row[PRIMARY_KEY].to_i }
        transmit_all(index, ids)
        sleep 0.1 # empirical throttle number
      end
    end

    # Данные, необходимые для записи в индекс сфинкса
    #
    # index  - ThinkingSphinx::Index
    # records - Array
    #
    # Returns Hash
    def transmitted_data(index, records)
      rows = connection.select_all(prepared_sql(index, records))

      rows.map! do |row|
        record = records.find { |r| r.id == row['sphinx_internal_id'].to_i }
        row.merge!(mva_attributes(index, record))

        row.each do |key, value|
          row[key] = case index.attributes_types_map[key]
                     when :integer then value.to_i
                     when :float then value.to_f
                     when :multi then type_cast_to_multi(value)
                     when :boolean then ActiveRecord::ConnectionAdapters::Column.value_to_boolean(value)
                     else value
                     end
        end

        row
      end
    end

    def prepared_sql(index, records)
      sql = index.single_query_sql.gsub(TEMPLATE_ID, "ANY(ARRAY[#{records.map(&:id).join(',')}])").sub('LIMIT 1', '')

      query_options = index.local_options[:with_sql]
      if query_options && (update_proc = query_options[:update]).respond_to?(:call)
        sql = update_proc.call(sql)
      end

      sql
    end

    # MVA data
    #
    # index - ThinkingSphinx::Index
    #
    # Returns Hash
    def mva_attributes(index, record)
      attrs = {}

      index.mva_sources.each do |name, mva_proc|
        attrs[name] = mva_proc.call(record)
      end if index.mva_sources

      attrs
    end

    # RealTime индексы модели
    #
    # Returns Array
    def rt_indexes
      @rt_indexes ||= klass.sphinx_indexes.select(&:rt?)
    end

    # Привести тип к мульти атрибуту
    #
    # value - NilClass or String or Array
    #
    # Returns Array
    def type_cast_to_multi(value)
      if value.nil?
        []
      elsif value.is_a?(String)
        value.split(',')
      else
        value
      end
    end

    ##
    # коннекция к бд
    #

    def connection
      @connection ||= klass.connection
    end
  end
end
