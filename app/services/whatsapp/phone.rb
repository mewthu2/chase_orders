module Whatsapp
  module Phone
    def self.normalize(value)
      digits = value.to_s.gsub(/\D/, '')
      digits = "55#{digits}" if [10, 11].include?(digits.length) && !value.to_s.start_with?('+')
      digits.match?(/\A[1-9]\d{7,14}\z/) ? "+#{digits}" : nil
    end
    def self.individual_jid?(jid) = jid.to_s.match?(/\A[1-9]\d{4,20}(?::\d+)?@(s\.whatsapp\.net|lid)\z/)
    def self.equivalent_jid?(left, right)
      return true if left == right
      a, b = [left, right].map { |jid| from_jid(jid)&.delete_prefix('+') }
      return false unless a && b && a.start_with?('55') && b.start_with?('55')
      [a, b].map { |n| n.length == 13 && n[4] == '9' ? n[0, 4] + n[5..] : n }.uniq.one?
    end
    def self.from_jid(jid)
      return unless jid.to_s.end_with?('@s.whatsapp.net')
      normalize("+#{jid.split('@').first.split(':').first}")
    end
  end
end
