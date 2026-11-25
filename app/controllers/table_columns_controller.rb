# Salva (ou volta ao padrão) a arrumação das colunas de uma tabela para o usuário logado.
class TableColumnsController < ApplicationController
  before_action :authenticate_user!

  def update
    # O JS manda JSON: { key:, columns: [{ k:, on: }, ...] }.
    columns = TableColumnPreference.clean(params.to_unsafe_h['columns'])
    return head(:unprocessable_content) if key.blank? || columns.empty?

    pref = current_user.table_column_preferences.find_or_initialize_by(table_key: key)
    pref.update!(columns: columns)
    head :no_content
  end

  def destroy
    current_user.table_column_preferences.where(table_key: key).delete_all
    head :no_content
  end

  private

  def key = params[:key].to_s.first(191).presence
end
