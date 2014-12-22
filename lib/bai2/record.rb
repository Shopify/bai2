require 'bai2/parser'

require 'time'

module Bai2

  # This class represents a record. It knows how to parse the single record
  # information, but has no knowledge of the structure of the file.
  #
  class Record


    RECORD_CODES = {'01' => :file_header,
                    '02' => :group_header,
                    '03' => :account_identifier,
                    '16' => :transaction_detail,
                    '49' => :account_trailer,
                    '88' => :continuation,
                    '98' => :group_trailer,
                    '99' => :file_trailer }


    # These parsing blocks are used below for the special date format BAI2 uses.
    # Assumes UTC, because we do not have timezone information.

    # Returns a date object
    ParseDate = ->(v) do
      Time.strptime("#{v} utc", '%y%m%d %Z')
    end

    # Returns a time interval in seconds, to be added to the date
    ParseMilitaryTime = -> (v) do
      v = '2400' if v == '9999'
      Time.strptime("#{v} utc", '%H%M %Z').to_i % 86400
    end

    # For each record code, this defines a simple way to automatically parse the
    # fields. Each field has a list of the keys. Some keys are not simply string
    # types, in which case they will be formatted as a tuple (key, fn), where fn
    # is a block (or anything that responds to `to_proc`) that will be called to
    # cast the value (e.g. `:to_i`).
    #
    SIMPLE_FIELD_MAP = {
      file_header: [
        :record_code,
        :sender,
        :receiver,
        [:file_creation_date, ParseDate],
        [:file_creation_time, ParseMilitaryTime],
        :file_identification_number,
        [:physical_record_length, :to_i],
        [:block_size, :to_i],
        [:version_number, ->(v) do
          unless v == "2"
            raise ParseError.new("Unsupported BAI version (#{v} != 2)")
          end; v.to_i
        end],
      ],
      group_header: [
        :record_code,
        :destination,
        :originator,
        :group_status,
        [:as_of_date, ParseDate],
        [:as_of_time, ParseMilitaryTime],
        :currency_code,
        :as_of_date_modifier,
      ],
      group_trailer: [
        :record_code,
        [:group_control_total, :to_i],
        [:number_of_accounts, :to_i],
        [:number_of_records, :to_i],
      ],
      account_trailer: [
        :record_code,
        [:account_control_total, :to_i],
        [:number_of_records, :to_i],
      ],
      file_trailer: [
        :record_code,
        [:file_control_total, :to_i],
        [:number_of_groups, :to_i],
        [:number_of_records, :to_i],
      ],
      account_identifier: [
        :record_code,
        :customer,
        :currency_code,
        :type_code,
        [:amount, :to_i],
        [:item_count, :to_i],
        :funds_type,
      ],
      continuation: [ # TODO: could continue any record at any point...
        :record_code,
        :continuation,
      ],
      # NOTE: transaction_detail is not present here, because it is too complex
      # for a simple mapping like this.
    }


    def initialize(line)
      @code = RECORD_CODES[line[0..1]]
      # clean / delimiter
      @raw = line.sub(/,\/.+$/, '').sub(/\/$/, '')
    end

    attr_reader :code, :raw

    # NOTE: fields is called upon first user, so as not to parse records right
    # away in case they might be merged with a continuation.
    #
    def fields
      @fields ||= parse_raw(@code, @raw)
    end

    # A record can be accessed like a hash.
    #
    def [](key)
      fields[key]
    end

    private

    def parse_raw(code, line)

      fields = (SIMPLE_FIELD_MAP[code] || [])
      if !fields.empty?
        split = line.split(',', fields.count).map(&:chomp)
        Hash[fields.zip(split).map do |k,v|
          next [k,v] if k.is_a?(Symbol)
          key, block = k
          [key, block.to_proc.call(v)]
        end]
      elsif respond_to?("parse_#{code}_fields".to_sym, true)
        send("parse_#{code}_fields".to_sym, line)
      else
        raise ParseError.new('Unknown record code.')
      end
    end

    # Special cases need special implementations.
    #
    # The rules here are pulled from the specification at this URL:
    # http://www.bai.org/Libraries/Site-General-Downloads/Cash_Management_2005.sflb.ashx
    #
    def parse_transaction_detail_fields(record)

      # split out the constant bits
      record_code, type_code, amount, funds_type, rest = record.split(',', 5).map(&:chomp)

      common = {
        record_code: record_code,
        type_code:   type_code,
        amount:      amount.to_i,
        funds_type:  funds_type,
      }

      # handle funds_type logic
      with_fund_availability = \
        case funds_type
        when 'S'
          now, next_day, later, rest = rest.split(',', 4).map(&:chomp)
          common.merge(
            availability: [
              {day: 0, amount: now},
              {day: 1, amount: now},
              {day: '>1', amount: now},
            ]
          )
        when 'V'
          value_date, value_hour, rest = rest.split(',', 3).map(&:chomp)
          value_hour = '2400' if value_hour == '9999'
          common.merge(
            value_dated: {date: value_date, hour: value_hour}
          )
        when 'D'
          field_count, rest = rest.split(',', 2).map(&:chomp)
          availability = field_count.to_i.times.map do
            days, amount, rest = rest.split(',', 3).map(&:chomp)
            {days: days.to_i, amount: amount}
          end
          common.merge(availability: availability)
        else
          common
        end

      # split the rest of the constant fields
      bank_ref, customer_ref, text = rest.split(',', 3).map(&:chomp)

      with_fund_availability.merge(
        bank_reference: bank_ref,
        customer_reference: customer_ref,
        text: text,
      )
    end

  end
end
