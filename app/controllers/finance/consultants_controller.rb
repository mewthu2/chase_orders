module Finance
  # Cadastro dos consultores e os nomes digitados nos pedidos que ainda não têm cadastro.
  class ConsultantsController < ApplicationController
    guard_screen :consultants, actions: { link_name: :edit }
    before_action :set_consultant, only: %i[edit update destroy]

    def index
      @consultants = Consultant.ordered
      @order_counts = B2bOrder.sale.where.not(consultant_id: nil).group(:consultant_id).count
      @pending_names = B2bOrder.sale.where(consultant_id: nil).where.not(salesperson_name: [nil, ''])
                               .group(Arel.sql('LOWER(TRIM(salesperson_name))')).pluck(Arel.sql('MIN(TRIM(salesperson_name))'), Arel.sql('COUNT(*)'))
                               .sort_by { |name, _| name.downcase }
    end

    def new
      @consultant = Consultant.new(name: params[:name])
    end

    def create
      @consultant = Consultant.new(consultant_params)
      if @consultant.save
        redirect_to finance_consultants_path, notice: "Consultor #{@consultant.name} cadastrado."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @consultant.update(consultant_params)
        redirect_to finance_consultants_path, notice: "Consultor #{@consultant.name} atualizado."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @consultant.destroy
      redirect_to finance_consultants_path, notice: "Consultor #{@consultant.name} excluído. Os pedidos dele ficam com o nome, como pendentes."
    end

    # Vincula todos os pedidos com um nome digitado (sem diferenciar maiúsculas e espaços) a um consultor,
    # existente (consultant_id) ou criado agora com esse nome (create=1).
    def link_name
      name = params[:name].to_s.squish
      consultant = if params[:create].present?
                     Consultant.find_or_create_by!(name: name.split.map(&:capitalize).join(' '))
                   else
                     Consultant.find_by(id: params[:consultant_id])
                   end
      return redirect_to(finance_consultants_path, alert: 'Escolha um consultor para vincular.') if consultant.nil? || name.blank?

      count = B2bOrder.sale.where(consultant_id: nil).where('LOWER(TRIM(salesperson_name)) = ?', name.downcase)
                      .update_all(consultant_id: consultant.id, salesperson_name: consultant.name, updated_at: Time.current)
      redirect_to finance_consultants_path, notice: "#{count} #{count == 1 ? 'pedido vinculado' : 'pedidos vinculados'} a #{consultant.name}."
    end

    private

    def set_consultant
      @consultant = Consultant.find(params[:id])
    end

    def consultant_params
      params.require(:consultant).permit(:name, :document, :phone, :email, :pix_key, :active)
    end
  end
end
