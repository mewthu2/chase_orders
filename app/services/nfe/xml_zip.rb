require 'zip'

module Nfe
  # ZIP com o XML de cada nota (NFe<chave>.xml) e, nas canceladas, o evento de cancelamento ao lado.
  # Os arquivos são baixados do storage em paralelo: um mês inteiro tem centenas de notas.
  class XmlZip
    THREADS = 8

    def self.call(notes) = new(notes).call

    def initialize(notes)
      @notes = notes.select(&:xml_available?)
    end

    def call
      files = download_all
      buffer = Zip::OutputStream.write_buffer do |zip|
        files.each do |name, content|
          zip.put_next_entry(name)
          zip.write(content)
        end
      end
      buffer.string
    end

    private

    def download_all
      jobs = @notes.flat_map do |note|
        base = note.access_key.presence ? "NFe#{note.access_key}" : "NFe-#{note.number}-serie#{note.series}"
        list = [["#{base}.xml", note.xml]]
        list << ["#{base}-cancelamento.xml", note.cancel_xml] if note.cancel_xml.attached?
        list
      end
      queue = Queue.new
      jobs.each_with_index { |job, i| queue << [i, *job] }
      results = Array.new(jobs.size)
      threads = Array.new([THREADS, jobs.size].min) do
        Thread.new do
          Rails.application.executor.wrap do
            while (item = next_job(queue))
              i, name, attachment = item
              results[i] = [name, attachment.download]
            end
          end
        end
      end
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { threads.each(&:join) }
      results
    end

    def next_job(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end
  end
end
