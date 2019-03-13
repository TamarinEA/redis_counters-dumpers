require 'forwardable'
require 'active_support/core_ext/hash/indifferent_access'
require 'active_support/core_ext/object/blank'
require_relative 'dsl/destination'

module RedisCounters
  module Dumpers
    # Класс представляет конечную точку сохранения данных счетчика.
    #
    # Описывает в какую модель (таблицу), какие поля имеющиеся в распоряжении дампера,
    # должны быть сохранены и каким образом.
    #
    # По сути, мерджит указанные поля из temp - таблицы, дампера
    # в указанную таблицу.
    #
    # Может использоваться как напрямую так и с помощью DSL (см. модуль RedisCounters::Dumpers::Dsl::Destination).
    class Destination
      extend Forwardable
      include ::RedisCounters::Dumpers::Dsl::Destination

      VALUE_DELIMITER = ','.freeze

      # Ссылка на родительский движек - дампер.
      attr_accessor :engine

      # Модель, в таблицу, которой будет производится мердж данных, AR::Model.
      attr_accessor :model

      # Список полей, из доступных дамперу, которые необходимо сохранить, Array.
      attr_accessor :fields

      # Список полей, по комбинации которых, будет происходить определение существования записи,
      # при мердже данных, Array.
      attr_accessor :key_fields

      # Список полей, которые будет инкрементированы при обновлении существующей записи, Array.
      attr_accessor :increment_fields

      # Карта полей - карта псевдонимов полей, Hash.
      # Названия полей в целевой таблице, могут отличаться от названий полей дампера.
      # Для сопоставления полей целевой таблицы и дампера, необходимо заполнить карту соответствия.
      # Карта, заполняется только для тех полей, названия которых отличаются.
      # Во всех свойствах, содержащий указания полей: fields, key_fields, increment_fields, conditions
      # используются имена конечных полей целевой таблицы.
      #
      # Example:
      #   fields_map = {:pages => :value, :date => :start_month_date}
      #
      # Означает, что целевое поле :pages, указывает на поле :value, дампера,
      # а целевое поле :date, указывает на поле :start_month_date, дампера.
      attr_accessor :fields_map

      # Список полей по которым будет группироваться таблицы с исходными данным, Array
      attr_accessor :group_by

      # Список дополнительных условий, которые применяются при обновлении целевой таблицы, Array of String.
      # Каждое условие представляет собой строку - часть SQL выражения, которое может включать именованные
      # параметры из числа доступных в хеше оббщих параметров дампера: engine.common_params.
      # Условия соеденяются через AND.
      attr_accessor :conditions

      # Список дополнительных условий, которые применяются для выборки из source-таблицы для обновления
      # target, Array of String.
      # Каждое условие представляет собой строку - часть SQL выражения, которое может включать именованные
      # параметры из числа доступных в хеше общих параметров дампера: engine.common_params.
      # Условия соединяются через AND.
      attr_accessor :source_conditions

      # Public: Опциональное выражение для определения одинаковых записей в исходной (source) и целевой (target)
      # таблицах. Эту опцию имеет смысл использовать если например нужно добавить функцию на какую-нибудь колонку,
      # например:
      #
      # matching_expr <<-SQL
      #   (source.company_id, source.date, coalesce(source.referer, '')) =
      #     (target.company_id, target.date, coalesce(target.referer, ''))
      # SQL
      #
      # Returns String
      attr_accessor :matching_expr

      # Разделитель значений, String.
      attr_accessor :value_delimiter

      def initialize(engine)
        @engine = engine
        @fields_map = HashWithIndifferentAccess.new
        @conditions = []
        @source_conditions = []
      end

      def merge
        sql = generate_query
        sql = model.send(:sanitize_sql, [sql, engine.common_params])
        connection.execute sql
      end

      def_delegator :model, :connection
      def_delegator :model, :quoted_table_name, :target_table
      def_delegator :engine, :temp_table_name, :source_table

      protected

      def generate_query
        target_fields = fields.join(', ')
        temp_source = "_source_#{source_table}"

        query = create_temp_table_query(temp_source)

        if increment_fields.present?
          query.concat(insert_with_update_query(temp_source, target_fields))
        else
          query.concat(insert_without_update_query(temp_source, target_fields))
        end

        query.concat(drop_temp_table_query(temp_source))
        query
      end

      def create_temp_table_query(temp_source)
        <<-SQL
          CREATE TEMP TABLE #{temp_source} ON COMMIT DROP AS
            SELECT #{selected_fields_expression}
            FROM #{source_table}
            #{source_conditions_expression}
            #{group_by_expression};
        SQL
      end

      def drop_temp_table_query(temp_source)
        <<-SQL
          DROP TABLE #{temp_source};
        SQL
      end

      def insert_with_update_query(temp_source, target_fields)
        <<-SQL
          WITH
            updated AS
            (
              UPDATE #{target_table} target
              SET
                #{updating_expression}
              FROM #{temp_source} AS source
              WHERE #{matching_expression}
                #{extra_conditions}
              RETURNING target.*
            )
          INSERT INTO #{target_table} (#{target_fields})
            SELECT #{target_fields}
            FROM #{temp_source} as source
            WHERE NOT EXISTS (
              SELECT 1
              FROM updated target
              WHERE #{matching_expression}
                #{extra_conditions}
          );
        SQL
      end

      def insert_without_update_query(temp_source, target_fields)
        <<-SQL
          INSERT INTO #{target_table} (#{target_fields})
            SELECT #{target_fields}
            FROM #{temp_source} as source;
        SQL
      end

      def selected_fields_expression
        full_fields_map.map { |target_field, source_field| "#{source_field} as #{target_field}" }.join(', ')
      end

      def group_by_expression
        return if group_by.blank?
        'GROUP BY %s' % [group_by.join(', ')]
      end

      def full_fields_map
        fields_map.reverse_merge(Hash[fields.zip(fields)])
      end

      def updating_expression
        increment_fields.map do |field|
          case model.columns_hash[field.to_s].type
          when :datetime, :date
            "#{field} = source.#{field}"
          when :text, :string
            "#{field} = array_to_string(ARRAY[source.#{field}, target.#{field}], '#{delimiter}')"
          else
            "#{field} = COALESCE(target.#{field}, 0) + source.#{field}"
          end
        end.join(', ')
      end

      def matching_expression
        matching_expr || default_matching_expr
      end

      def default_matching_expr
        source_key_fields = key_fields.map { |field| "source.#{field}" }.join(', ')
        target_key_fields = key_fields.map { |field| "target.#{field}" }.join(', ')
        "(#{source_key_fields}) = (#{target_key_fields})"
      end

      def extra_conditions
        result = conditions.map { |condition| "(#{condition})" }.join(' AND ')
        result.present? ? "AND #{result}" : result
      end

      def source_conditions_expression
        return if source_conditions.blank?

        "WHERE #{source_conditions.map { |source_condition| "(#{source_condition})" }.join(' AND ')}"
      end

      def delimiter
        value_delimiter || VALUE_DELIMITER
      end
    end
  end
end
